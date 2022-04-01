// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.8.9;

// Modified from Frax veFXS. Original idea and based on Curve Finance's veCRV
// https://resources.curve.fi/faq/vote-locking-boost
// https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/VotingEscrow.vy
//
//@notice Votes have a weight depending on time, so that users are
//        committed to the future of (whatever they are voting for)
//@dev Vote weight decays linearly over time. Lock time cannot be
//     more than `MAXTIME` (3 years).

// Voting escrow to have time-weighted votes
// Votes have a weight depending on time, so that users are committed
// to the future of (whatever they are voting for).
// The weight in this implementation is linear, and lock cannot be more than maxtime:
// w ^
// 1 +        /
//   |      /
//   |    /
//   |  /
//   |/
// 0 +--------+------> time
//       maxtime (3 years?)


import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeMath } from "@openzeppelin/contracts/utils/math/SafeMath.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";

// Inheritance
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";

// # Interface for checking whether address belongs to a whitelisted
// # type of a smart wallet.
// # When new types are added - the whole contract is changed
// # The check() method is modifying to be able to use caching
// # for individual wallet addresses
interface SmartWalletChecker {
    function check(address addr) external returns (bool);
}

/// @title VEToken
/// @notice Explain to an end user what this does
/// @dev Explain to a developer any extra details
contract VEToken is ReentrancyGuard, Pausable, Ownable {
    using SafeMath for uint256;
    using SafeERC20 for ERC20;

    /* ========== STATE VARIABLES ========== */

    address public token; // MON
    uint256 public supply;

    uint256 public epoch;
    mapping (address => LockedBalance) public locked;
    Point[100000000000000000000000000000] public pointHistory; // epoch -> unsigned point
    mapping (address => Point[1000000000]) public userPointHistory;
    mapping (address => uint256) public userPointEpoch;
    mapping (uint256 => uint256) public slopeChanges; // time -> signed slope change

    // Aragon's view methods for 
    address public controller;
    bool public transfersEnabled;

    // veFXS token related
    string public name;
    string public symbol;
    string public version;
    uint256 public decimals;

    // Checker for whitelisted (smart contract) wallets which are allowed to deposit
    // The goal is to prevent tokenizing the escrow
    address public futureSmartWalletChecker;
    address public smartWalletChecker;

    address public admin;  // Can and will be a smart contract
    address public futureAdmin;

    int128 public constant DEPOSIT_FOR_TYPE = 0;
    int128 public constant CREATE_LOCK_TYPE = 1;
    int128 public constant INCREASE_LOCK_AMOUNT = 2;
    int128 public constant INCREASE_UNLOCK_TIME = 3;

    address public constant ZERO_ADDRESS = address(0);

    uint256 public constant WEEK = 7 * 86400; // all future times are rounded by week
    uint256 public constant MAXTIME = 3 * 365 * 86400; // 3 years
    uint256 public constant MULTIPLIER = 10 ** 18;

    // We cannot really do block numbers per se b/c slope is per time, not per block
    // and per block could be fairly bad b/c Ethereum changes blocktimes.
    // What we can do is to extrapolate ***At functions
    struct Point {
        uint256 bias;
        uint256 slope; // dweight / dt
        uint256 ts;
        uint256 blk; // block
    }

    struct LockedBalance {
        uint256 amount;
        uint256 end;
    }

    /* ========== MODIFIERS ========== */

    modifier onlyAdmin {
        require(msg.sender == admin, "You are not the admin");
        _;
    }

    /* ========== CONSTRUCTOR ========== */
    // token_addr: address, _name: String[64], _symbol: String[32], _version: String[32]
    /**
        * @notice Contract constructor
        * @param tokenAddr `ERC20CRV` token address
        * @param _name Token name
        * @param _symbol Token symbol
        * @param _version Contract version - required for Aragon compatibility
    */
    constructor (
        address tokenAddr,
        string memory _name,
        string memory _symbol,
        string memory _version
    ) {
        admin = msg.sender;
        token = tokenAddr;
        pointHistory[0].blk = _blockNumber();
        pointHistory[0].ts = _blockTimestamp();
        controller = msg.sender;
        transfersEnabled = true;

        uint256 _decimals = ERC20(tokenAddr).decimals();
        assert(_decimals <= 255);
        decimals = _decimals;

        name = _name;
        symbol = _symbol;
        version = _version;
    }

    /*=========== Pausable =========*/
    function pause() public onlyOwner whenNotPaused {
        _pause();
    }

    function unpause() public onlyOwner whenPaused {
        _unpause();
    }

    /* ========== VIEWS ========== */

    // Constant structs not allowed yet, so this will have to do
    function EMPTY_POINT_FACTORY() internal pure returns (Point memory){
        return Point({
            bias: 0, 
            slope: 0, 
            ts: 0, 
            blk: 0
        });
    }

    // Constant structs not allowed yet, so this will have to do
    function EMPTY_LOCKED_BALANCE_FACTORY() internal pure returns (LockedBalance memory){
        return LockedBalance({
            amount: 0, 
            end: 0 
        });
    }

    /**
        * @notice Get the most recently recorded rate of voting power decrease for `addr`
        * @param addr Address of the user wallet
        * @return Value of the slope
    */
    function getLastUserSlope(address addr) external view returns (uint256) {
        uint256 uepoch = userPointEpoch[addr];
        return userPointHistory[addr][uepoch].slope;
    }

    /**
        * @notice Get the timestamp for checkpoint `_idx` for `_addr`
        * @param _addr User wallet address
        * @param _idx User epoch number
        * @return Epoch time of the checkpoint
    */
    function userPointHistoryTS(address _addr, uint256 _idx) external view returns (uint256) {
        return userPointHistory[_addr][_idx].ts;
    }

    /**
        * @notice Get timestamp when `_addr`'s lock finishes
        * @param _addr User wallet
        * @return Epoch time of the lock end
    */
    function lockedEnd(address _addr) external view returns (uint256) {
        return locked[_addr].end;
    }

    /**
        * @notice Get the current voting power for `msg.sender` at the specified timestamp
        * @dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
        * @param addr User wallet address
        * @param _t Epoch time to return voting power at
        * @return User voting power
    */
    function balanceOf(address addr, uint256 _t) public view returns (uint256) {
        uint256 _epoch = userPointEpoch[addr];
        if (_epoch == 0) {
            return 0;
        }
        else {
            Point memory lastPoint = userPointHistory[addr][_epoch];
            uint256 delta = lastPoint.slope * ((_t) - (lastPoint.ts));
            if (delta <= lastPoint.bias) {
                lastPoint.bias -= delta;
            } else {
                lastPoint.bias = 0;
            }
            return uint256(lastPoint.bias);
        }
    }

    /**
        * @notice Get the current voting power for `msg.sender` at the current timestamp
        * @dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
        * @param addr User wallet address
        * @return User voting power
    */
    function balanceOf(address addr) public view returns (uint256) {
        return balanceOf(addr, _blockTimestamp());
    }

    /**
        * @notice Measure voting power of `addr` at block height `_block`
        * @dev Adheres to MiniMe `balanceOfAt` interface: https://github.com/Giveth/minime
        * @param addr User's wallet address
        * @param _block Block to calculate the voting power at
        * @return Voting power
    */
    function balanceOfAt(address addr, uint256 _block) external view returns (uint256) {
        // Copying and pasting totalSupply code because Vyper cannot pass by
        // reference yet
        require(_block <= _blockNumber(), "VE: Invalid block");

        // Binary search
        uint256 _min = 0;
        uint256 _max = userPointEpoch[addr];

        // Will be always enough for 128-bit numbers
        for(uint i = 0; i < 128; i++){
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 1) / 2;
            if (userPointHistory[addr][_mid].blk <= _block) {
                _min = _mid;
            }
            else {
                _max = _mid - 1;
            }
        }

        Point memory upoint = userPointHistory[addr][_min];

        uint256 maxEpoch = epoch;
        uint256 _epoch = findBlockEpoch(_block, maxEpoch);
        Point memory point0 = pointHistory[_epoch];
        uint256 dBlock = 0;
        uint256 dT = 0;

        if (_epoch < maxEpoch) {
            Point memory point1 = pointHistory[_epoch + 1];
            dBlock = point1.blk - point0.blk;
            dT = point1.ts - point0.ts;
        }
        else {
            dBlock = _blockNumber() - point0.blk;
            dT = _blockTimestamp() - point0.ts;
        }

        uint256 blockTime = point0.ts;
        if (dBlock != 0) {
            blockTime += dT * (_block - point0.blk) / dBlock;
        }

        upoint.bias -= upoint.slope * ((blockTime) - (upoint.ts));
        if (upoint.bias >= 0) {
            return uint256(upoint.bias);
        }
        else {
            return 0;
        }
    }

    /**
        * @notice Calculate total voting power at the specified timestamp
        * @dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
        * @return Total voting power
    */
    function totalSupply(uint256 t) public view returns (uint256) {
        uint256 _epoch = epoch;
        Point memory lastPoint = pointHistory[_epoch];
        return supplyAt(lastPoint, t);
    }

    /**
        * @notice Calculate total voting power at the current timestamp
        * @dev Adheres to the ERC20 `totalSupply` interface for Aragon compatibility
        * @return Total voting power
    */
    function totalSupply() public view returns (uint256) {
        return totalSupply(_blockTimestamp());
    }

    /**
        * @notice Calculate total voting power at some point in the past
        * @param _block Block to calculate the total voting power at
        * @return Total voting power at `_block`
    */
    function totalSupplyAt(uint256 _block) external view returns (uint256) {
        require(_block <= _blockNumber(), "VE: Invalid block");
        uint256 _epoch = epoch;
        uint256 targetEpoch = findBlockEpoch(_block, _epoch);

        Point memory point = pointHistory[targetEpoch];
        uint256 dt = 0;

        if (targetEpoch < _epoch) {
            Point memory pointNext = pointHistory[targetEpoch + 1];
            if (point.blk != pointNext.blk) {
                dt = ((_block - point.blk) * (pointNext.ts - point.ts)) / (pointNext.blk - point.blk);
            }
        }
        else {
            if (point.blk != _blockNumber()) {
                dt = ((_block - point.blk) * (_blockTimestamp() - point.ts)) / (_blockNumber() - point.blk);
            }
        }

        // Now dt contains info on how far are we beyond point
        return supplyAt(point, point.ts + dt);
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    /**
        * @notice Check if the call is from a whitelisted smart contract, revert if not
        * @param addr Address to be checked
    */
    function _assertNotContract(address addr) internal {
        if (addr != tx.origin) {
            address checker = smartWalletChecker;
            if (checker != ZERO_ADDRESS){
                if (SmartWalletChecker(checker).check(addr)){
                    return;
                }
            }
            revert("Depositor not allowed");
        }
    }

    /**
        * @notice Record global and per-user data to checkpoint
        * @param addr User's wallet address. No user checkpoint if 0x0
        * @param oldLocked Previous locked amount / end lock time for the user
        * @param newLocked New locked amount / end lock time for the user
    */
    function _checkpoint(address addr, LockedBalance memory oldLocked, LockedBalance memory newLocked) internal {
        Point memory uOld = EMPTY_POINT_FACTORY();
        Point memory uNew = EMPTY_POINT_FACTORY();
        uint oldSlope = 0;
        uint newSlope = 0;
        uint256 _epoch = epoch;

        if (addr != ZERO_ADDRESS){
            // Calculate slopes and biases
            // Kept at zero when they have to
            if ((oldLocked.end > _blockTimestamp()) && (oldLocked.amount > 0)){
                uOld.slope = oldLocked.amount / (MAXTIME);
                uOld.bias = uOld.slope * ((oldLocked.end) - (_blockTimestamp()));
            }

            if ((newLocked.end > _blockTimestamp()) && (newLocked.amount > 0)){
                uNew.slope = newLocked.amount / (MAXTIME);
                uNew.bias = uNew.slope * ((newLocked.end) - (_blockTimestamp()));
            }

            // Read values of scheduled changes in the slope
            // oldLocked.end can be in the past and in the future
            // newLocked.end can ONLY by in the FUTURE unless everything expired: than zeros
            oldSlope = slopeChanges[oldLocked.end];
            if (newLocked.end != 0) {
                if (newLocked.end == oldLocked.end) {
                    newSlope = oldSlope;
                }
                else {
                    newSlope = slopeChanges[newLocked.end];
                }
            }

        }

        Point memory lastPoint = Point({
            bias: 0, 
            slope: 0, 
            ts: _blockTimestamp(), 
            blk: _blockNumber()
        });
        if (_epoch > 0) {
            lastPoint = pointHistory[_epoch];
        }
        uint256 lastCheckpoint = lastPoint.ts;

        // initialLastPoint is used for extrapolation to calculate block number
        // (approximately, for *At methods) and save them
        // as we cannot figure that out exactly from inside the contract
        Point memory initialLastPoint = lastPoint;
        uint256 blockSlope = 0; // dblock/dt
        if (_blockTimestamp() > lastPoint.ts) {
            blockSlope = MULTIPLIER * (_blockNumber() - lastPoint.blk) / (_blockTimestamp() - lastPoint.ts);
        }

        // If last point is already recorded in this block, slope=0
        // But that's ok b/c we know the block in such case

        // Go over weeks to fill history and calculate what the current point is
        uint256 tI = (lastCheckpoint / WEEK) * WEEK;
        for(uint i = 0; i < 255; i++){
            // Hopefully it won't happen that this won't get used in 4 years!
            // If it does, users will be able to withdraw but vote weight will be broken
            tI += WEEK;
            uint256 dSlope = 0;
            if (tI > _blockTimestamp()) {
                tI = _blockTimestamp();
            }
            else {
                dSlope = slopeChanges[tI];
            }
            lastPoint.bias -= lastPoint.slope * ((tI) - (lastCheckpoint));
            lastPoint.slope += dSlope;
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0; // This can happen
            }
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0; // This cannot happen - just in case
            }
            lastCheckpoint = tI;
            lastPoint.ts = tI;
            lastPoint.blk = initialLastPoint.blk + blockSlope * (tI - initialLastPoint.ts) / MULTIPLIER;
            _epoch += 1;
            if (tI == _blockTimestamp()){
                lastPoint.blk = _blockNumber();
                break;
            }
            else {
                pointHistory[_epoch] = lastPoint;
            }
        }

        epoch = _epoch;
        // Now pointHistory is filled until t=now

        if (addr != ZERO_ADDRESS) {
            // If last point was in this block, the slope change has been applied already
            // But in such case we have 0 slope(s)
            lastPoint.slope += (uNew.slope - uOld.slope);
            lastPoint.bias += (uNew.bias - uOld.bias);
            if (lastPoint.slope < 0) {
                lastPoint.slope = 0;
            }
            if (lastPoint.bias < 0) {
                lastPoint.bias = 0;
            }
        }

        // Record the changed point into history
        pointHistory[_epoch] = lastPoint;

        if (addr != ZERO_ADDRESS) {
            // Schedule the slope changes (slope is going down)
            // We subtract new_user_slope from [newLocked.end]
            // and add old_user_slope to [oldLocked.end]
            if (oldLocked.end > _blockTimestamp()) {
                // oldSlope was <something> - uOld.slope, so we cancel that
                oldSlope += uOld.slope;
                if (newLocked.end == oldLocked.end) {
                    oldSlope -= uNew.slope;  // It was a new deposit, not extension
                }
                slopeChanges[oldLocked.end] = oldSlope;
            }

            if (newLocked.end > _blockTimestamp()) {
                if (newLocked.end > oldLocked.end) {
                    newSlope -= uNew.slope;  // old slope disappeared at this point
                    slopeChanges[newLocked.end] = newSlope;
                }
                // else: we recorded it already in oldSlope
            }

            // Now handle user history
            // Second function needed for 'stack too deep' issues
            _checkpointPartTwo(addr, uNew.bias, uNew.slope);
        }

    }
    /**
        * @notice Needed for 'stack too deep' issues in _checkpoint()
        * @param addr User's wallet address. No user checkpoint if 0x0
        * @param _bias from unew
        * @param _slope from unew
    */
    function _checkpointPartTwo(address addr, uint256 _bias, uint256 _slope) internal {
        uint256 userEpoch = userPointEpoch[addr] + 1;

        userPointEpoch[addr] = userEpoch;
        userPointHistory[addr][userEpoch] = Point({
            bias: _bias, 
            slope: _slope, 
            ts: _blockTimestamp(), 
            blk: _blockNumber()
        });
    }

    /**
        * @notice Deposit and lock tokens for a user
        * @param _addr User's wallet address
        * @param _value Amount to deposit
        * @param unlockTime New time when to unlock the tokens, or 0 if unchanged
        * @param lockedBalance Previous locked amount / timestamp
    */
    function _depositFor(address _addr, uint256 _value, uint256 unlockTime, LockedBalance memory lockedBalance, int128 _type) internal {
        LockedBalance memory _locked = lockedBalance;
        uint256 supplyBefore = supply;

        supply = supplyBefore + _value;
        LockedBalance memory oldLocked = _locked;
        // Adding to existing lock, or if a lock is expired - creating a new one
        _locked.amount += (_value);
        if (unlockTime != 0) {
            _locked.end = unlockTime;
        }
        locked[_addr] = _locked;

        // Possibilities:
        // Both oldLocked.end could be current or expired (>/< _blockTimestamp())
        // value == 0 (extend lock) or value > 0 (add to lock or extend lock)
        // _locked.end > _blockTimestamp() (always)
        _checkpoint(_addr, oldLocked, _locked);

        if (_value != 0) {
            assert(ERC20(token).transferFrom(_addr, address(this), _value));
        }

        emit Deposit(_addr, _value, _locked.end, _type, _blockTimestamp());
        emit Supply(supplyBefore, supplyBefore + _value);
    }

    // The following ERC20/minime-compatible methods are not real balanceOf and supply!
    // They measure the weights for the purpose of voting, so they don't represent
    // real coins.
    /**
        * @notice Binary search to estimate timestamp for block number
        * @param _block Block to find
        * @param maxEpoch Don't go beyond this epoch
        * @return Approximate timestamp for block
    */
    function findBlockEpoch(uint256 _block, uint256 maxEpoch) internal view returns (uint256) {
        // Binary search
        uint256 _min = 0;
        uint256 _max = maxEpoch;

        // Will be always enough for 128-bit numbers
        for (uint i = 0; i < 128; i++){
            if (_min >= _max) {
                break;
            }
            uint256 _mid = (_min + _max + 1) / 2;
            if (pointHistory[_mid].blk <= _block) {
                _min = _mid;
            }
            else {
                _max = _mid - 1;
            }
        }

        return _min;
    }

    /**
        * @notice Calculate total voting power at some point in the past
        * @param point The point (bias/slope) to start search from
        * @param t Time to calculate the total voting power at
        * @return Total voting power at that time
    */
    function supplyAt(Point memory point, uint256 t) internal view returns (uint256) {
        Point memory lastPoint = point;
        uint256 tI = (lastPoint.ts / WEEK) * WEEK;

        for(uint i = 0; i < 255; i++){
            tI += WEEK;
            uint dSlope = 0;
            if (tI > t) {
                tI = t;
            }
            else {
                dSlope = slopeChanges[tI];
            }
            lastPoint.bias -= lastPoint.slope * ((tI) - (lastPoint.ts));
            if (tI == t) {
                break;
            }
            lastPoint.slope += dSlope;
            lastPoint.ts = tI;
        }

        if (lastPoint.bias < 0) {
            lastPoint.bias = 0;
        }
        return uint256(lastPoint.bias);
    }

    
    /* ========== MUTATIVE FUNCTIONS ========== */

    /**
        * @notice Record global data to checkpoint
    */
    function checkpoint(address) external {
        _checkpoint(ZERO_ADDRESS, EMPTY_LOCKED_BALANCE_FACTORY(), EMPTY_LOCKED_BALANCE_FACTORY());
    }

    /**
        * @notice Deposit and lock tokens for a user
        * @dev Anyone (even a smart contract) can deposit for someone else, but
        cannot extend their locktime and deposit for a brand new user
        * @param _addr User's wallet address
        * @param _value Amount to add to user's lock
    */
    function depositFor(address _addr, uint256 _value) external nonReentrant {
        LockedBalance memory _locked = locked[_addr];
        require (_value > 0, "need non-zero value");
        require (_locked.amount > 0, "No existing lock found");
        require (_locked.end > _blockTimestamp(), "Cannot add to expired lock");
        _depositFor(_addr, _value, 0, locked[_addr], DEPOSIT_FOR_TYPE);
    }

    /**
        * @notice Deposit `_value` tokens for `msg.sender` and lock until `_unlockTime`
        * @param _value Amount to deposit
        * @param _unlockTime Epoch time when tokens unlock, rounded down to whole weeks
    */
    function createLock(uint256 _value, uint256 _unlockTime) external nonReentrant {
        _assertNotContract(msg.sender);
        uint256 blockTimestamp = _blockTimestamp();
        uint256 unlockTime = (_unlockTime / WEEK) * WEEK ; // Locktime is rounded down to weeks
        LockedBalance memory _locked = locked[msg.sender];

        require (_value > 0, "need non-zero value");
        require (_locked.amount == 0, "Withdraw old tokens first");
        require (unlockTime > blockTimestamp, "Unlock time must be future");
        require (unlockTime <= blockTimestamp + MAXTIME, "Voting lock can be 3 years max");
        _depositFor(msg.sender, _value, unlockTime, _locked, CREATE_LOCK_TYPE);
    }

    /**
        * @notice Deposit `_value` additional tokens for `msg.sender`
        without modifying the unlock time
        * @param _value Amount of tokens to deposit and add to the lock
    */
    function increaseAmount(uint256 _value) external nonReentrant {
        _assertNotContract(msg.sender);
        LockedBalance memory _locked = locked[msg.sender];

        require(_value > 0, "need non-zero value");
        require(_locked.amount > 0, "No existing lock found");
        require(_locked.end > _blockTimestamp(), "Cannot add to expired lock.");

        _depositFor(msg.sender, _value, 0, _locked, INCREASE_LOCK_AMOUNT);
    }

    /**
        * @notice Extend the unlock time for `msg.sender` to `_unlockTime`
        * @param _unlockTime New epoch time for unlocking
    */
    function increaseUnlockTime(uint256 _unlockTime) external nonReentrant {
        _assertNotContract(msg.sender);
        LockedBalance memory _locked = locked[msg.sender];
        uint256 unlockTime = (_unlockTime / WEEK) * WEEK; // Locktime is rounded down to weeks

        require(_locked.end > _blockTimestamp(), "Lock expired");
        require(_locked.amount > 0, "Nothing is locked");
        require(unlockTime > _locked.end, "Can only increase lock duration");
        require(unlockTime <= _blockTimestamp() + MAXTIME, "Voting lock can be 3 years max");

        _depositFor(msg.sender, 0, unlockTime, _locked, INCREASE_UNLOCK_TIME);
    }

    /**
        * @notice Withdraw all tokens for `msg.sender`ime`
        * @dev Only possible if the lock has expired
    */
    function withdraw() external nonReentrant {
        LockedBalance memory _locked = locked[msg.sender];
        uint256 blockTimestamp = _blockTimestamp();
        require(blockTimestamp >= _locked.end, "The lock didn't expire");
        uint256 value = uint256(_locked.amount);

        LockedBalance memory oldLocked = _locked;
        _locked.end = 0;
        _locked.amount = 0;
        locked[msg.sender] = _locked;
        uint256 supplyBefore = supply;
        supply = supplyBefore - value;

        // oldLocked can have either expired <= timestamp or zero end
        // _locked has only 0 end
        // Both can have >= 0 amount
        _checkpoint(msg.sender, oldLocked, _locked);

        require(ERC20(token).transfer(msg.sender, value), "VEToken: Transfer failed");

        emit Withdraw(msg.sender, value, blockTimestamp);
        emit Supply(supplyBefore, supplyBefore - value);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    /**
        * @notice Transfer ownership of VotingEscrow contract to `addr`
        * @param addr Address to have ownership transferred to
    */
    function commitTransferOwnership(address addr) external onlyAdmin {
        futureAdmin = addr;
        emit CommitOwnership(addr);
    }

    /**
        * @notice Apply ownership transfer
    */
    function applyTransferOwnership() external onlyAdmin {
        address _admin = futureAdmin;
        assert (_admin != ZERO_ADDRESS);  // dev: admin not set
        admin = _admin;
        emit ApplyOwnership(_admin);
    }

    /**
        * @notice Set an external contract to check for approved smart contract wallets
        * @param addr Address of Smart contract checker
    */
    function commitSmartWalletChecker(address addr) external onlyAdmin {
        futureSmartWalletChecker = addr;
    }

    /**
        * @notice Apply setting external contract to check approved smart contract wallets
    */
    function applySmartWalletChecker() external onlyAdmin {
        smartWalletChecker = futureSmartWalletChecker;
    }

    /**
        * @notice Dummy method for compatibility with Aragon
        * @dev Dummy method required for Aragon compatibility
    */
    function changeController(address _newController) external {
        require(msg.sender == controller, "VEToken: not controller");
        controller = _newController;
    }

    // Added to support recovering LP Rewards and other mistaken tokens from other systems to be distributed to holders
    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyAdmin {
        // Admin cannot withdraw the staking token from the contract unless currently migrating
        // if(!migrationsOn){
        //     require(tokenAddress != address(FXS), "Not in migration"); // Only Governance / Timelock can trigger a migration
        // }
        // Only the owner address can ever receive the recovery withdrawal
        ERC20(tokenAddress).transfer(admin, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    function _blockTimestamp() internal view returns (uint256) {
        return block.timestamp;
    }

    function _blockNumber() internal view returns (uint256) {
        return block.number;
    }

    /* ========== EVENTS ========== */

    event Recovered(address token, uint256 amount);
    event CommitOwnership(address admin);
    event ApplyOwnership(address admin);
    event Deposit(address indexed provider, uint256 value, uint256 indexed locktime, int128 _type, uint256 ts);
    event Withdraw(address indexed provider, uint256 value, uint256 ts);
    event Supply(uint256 prevSupply, uint256 supply);
}
