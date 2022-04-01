//SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.9;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { FixedPointMathLib } from "../lib/FixedPointMathLib.sol";
import { SafeTransferLib } from "../lib/SafeTransferLib.sol";
import { IveToken } from "../interfaces/IveToken.sol";
import { IGauge } from "../interfaces/IGauge.sol";
import { LiquidityGauge } from "./LiquidityGauge.sol";

/// @title GaugeController
/// @notice Controls reward distribution
/// @dev Explain to a developer any extra details
contract GaugeController is Ownable {

    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;
 
    event GenesisCreated(address indexed by, uint256 startTime);
    event EpochCreated(uint256 start, uint256 end, address indexed reaper);
    event RewardsTokenSet(address indexed tokenAddress, address indexed by);
    event VeTokenSet(address indexed tokenAddress, address indexed by);
    event GaugeCreated(address indexed by, uint256 startTime);

    struct Epoch {
        uint256 start;
        uint256 end;
        uint256 totalVotes;
        address reaper;
    }

    /// @notice List of all the created gauges.
    address[] public gauges;

    /// @notice The number of votes a gauge has received in the current epoch.
    /// @dev This is reset to 0 each epoch.
    mapping(address => uint256) public gaugeVotes;

    /// @notice List of all the created epochs.
    Epoch[] private _epochs;

    /// @notice Represents a percentage state of the pie. 1 WAD = 100%
    /// @dev Explain to a developer any extra details
    mapping(address => uint256) internal _currentRelativeWeight;

    uint256 public constant EPOCH_LENGTH = 14 days;

    uint256 public constant REAPER_FEE = 15 * 1e15; // 1.5%

    IveToken public veToken;
    ERC20 public rewardsToken;

    /// @notice Keeps track on if account has claimed rewards in the current epoch.
    /// @dev Mapping: epoch number => account => claimed.
    mapping(uint256 => mapping(address => bool)) public rewardsClaimed;

    /// @notice Tracks if an account has voted in a given epoch
    /// @dev epoch number => account => voted
    mapping(uint256 => mapping(address => bool)) public hasVoted;

    bool internal _isInitialized;

    /*///////////////////////////////////////////////////////////////
                            ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    /// @notice Creates the first epoch.
    /// @dev Can only be called by contract owner. Can only be called once.
    /// @param startTime The start time of the first epoch. All future epochs
    /// start and end times are relative to this time. 
    function createGenesisEpoch(uint256 startTime) external onlyOwner {
        require(!_isInitialized, "GC: Genesis already created");
        _epochs.push(_createFirstEpoch(startTime));
        _isInitialized = true;
    }

    function setRewardsToken(address _rewards) external onlyOwner {
        rewardsToken = ERC20(_rewards);
    }

    function setVeToken(address _ve) external onlyOwner {
        veToken = IveToken(_ve);
    }

    /// @notice Creates a new gauge which can then start to receive rewards
    /// @dev Can ony be called by owner of this contract.
    /// Gauges have to be voted on by veToken holders to receive any rewards
    function createGauge() external onlyOwner {
        LiquidityGauge gauge = new LiquidityGauge();
        gauges.push(address(gauge));
    }

    /// @notice Returns an array of all the gauge addresses.
    /// @return g the list of gauge addresses.
    function allGauges() external view returns (address[] memory g) {
        g = gauges;
    }

    /// @notice Returns the number of gauges in existence.
    /// @return n the number of gauges.
    function numberOfGauges() external view returns (uint n) {
        n = gauges.length;
    }

    /*///////////////////////////////////////////////////////////////
                                VOTING
    //////////////////////////////////////////////////////////////*/

    /// @notice Records an address's vote for the specified gauge.
    /// @dev An account can only vote once per epoch. The weight of the vote is the 
    /// user's current veToken balance.
    function vote(address gaugeAddress) external {
        require(_epochs.length > 0, "GC: No epochs");
        require(_canVote(), "GC: Can not vote");
        require(_isValidGauge(gaugeAddress), "GC: Invalid address");
        
        uint256 votePower = veToken.balanceOf(msg.sender);

        require(votePower > 0, "GC: No voting power");

        gaugeVotes[gaugeAddress] += votePower;
        _currentEpoch().totalVotes += votePower;
        hasVoted[epochNumber()][msg.sender] = true;
    }

    function currentEpochTotalVotes() external view returns (uint256) {
        return _currentEpoch().totalVotes;
    }

    function _canVote() internal view returns (bool) {
        return veToken.balanceOf(msg.sender) != 0 && !_votedInEpoch(epochNumber());
    }

    function _votedInEpoch(uint256 epoch) internal view returns (bool) {
        return hasVoted[epoch][msg.sender];
    }

    /// @notice Checks if a specified address is a valid gauge address.
    /// @return isValid is true if `gaugeAddress` is of a valid gauge, false otherwise.
    function _isValidGauge(address gaugeAddress) internal view returns (bool isValid) {
        isValid = false;
        for (uint256 i = 0; i < gauges.length; i++) {
            if (gauges[i] == gaugeAddress) {
                isValid = true;
            }
        }
    }

    /*///////////////////////////////////////////////////////////////
                           REWARDS MANAGEMENT
    //////////////////////////////////////////////////////////////*/
    /// @notice Allocate weights to gauges for the current epoch.
    /// @dev Can only be called once per epoch. The caller of this function specifies the
    /// address that should receive the reward for calling.
    /// This function also distributes rewards accumulated in the controller to the
    /// individual gauges, proportionally based on the votes received in current epoch.
    /// @param reaper The address that should receive reaper fees.
    function rebalance(address reaper) external {
        require(_isInitialized, "GC: Not initialized");
        Epoch storage epoch = _currentEpoch();
        require(epoch.start != 0 && epoch.end <= block.timestamp, "GC: Not ended");

        uint256 totalWeights = 0;
        for (uint256 i = 0; i < gauges.length; i++) {
            totalWeights += gaugeVotes[gauges[i]];
        }
        for (uint256 i = 0; i < gauges.length; i++) {
            address gaugeAddress = gauges[i];
            uint256 gaugeWeight = gaugeVotes[gaugeAddress];
            _currentRelativeWeight[gaugeAddress] = gaugeWeight.divWadDown(totalWeights);
        }

        _distribute(reaper);
        _resetGauges();
        _epochs.push(_createEpoch(reaper));
    }

    function _distribute(address reaper) internal {
        require(_isInitialized, "GC: Not initialized");
        uint256 currentBalance = rewardsToken.balanceOf(address(this));
        uint256 reaperReward = currentBalance.mulWadDown(REAPER_FEE);
        uint256 pie = currentBalance - reaperReward;

        for (uint256 i = 0; i < gauges.length; i++) {
            address gaugeAddress = gauges[i];
            uint256 weightedWeight = _currentRelativeWeight[gaugeAddress];
            uint256 portion = pie.divWadDown(weightedWeight); // * gauge_weight / total weights
            rewardsToken.transfer(gaugeAddress, portion);
        }
        rewardsToken.safeTransfer(reaper, reaperReward);
    }

    function _resetGauges() internal {
        uint256 timestamp = ts();
        for (uint256 i = 0; i < gauges.length; i++) {
            uint256 pieSize = rewardsToken.balanceOf(gauges[i]);
           IGauge(gauges[i]).setSnapshot(timestamp, pieSize, gaugeVotes[gauges[i]]); 
        }
    }

    function _createFirstEpoch(uint256 startTime) internal view returns (Epoch memory epoch) {
        require(!_isInitialized, "GC: Already initialized");
        require(startTime > block.timestamp, "GC: Invalid start");
        uint256 endTime = startTime + EPOCH_LENGTH;
        epoch = Epoch({
            start: startTime ,
            end: endTime,
            totalVotes: 0,
            reaper: msg.sender
        });
    }

    function _createEpoch(address reaper) internal view returns (Epoch memory epoch) {
        uint256 startTime = block.timestamp;
        uint256 endTime = _currentEpoch().end + EPOCH_LENGTH;

        while (endTime < startTime) {
            endTime +=  EPOCH_LENGTH;
        }
        epoch = Epoch({
            start: startTime,
            end: endTime,
            totalVotes: 0,
            reaper: reaper
        });
    }

    function ts() public view returns (uint256) {
        return block.timestamp;
    }

    /// @notice Explain to an end user what this does
    /// @dev Will revert if no epochs exist, which is the expected behavior.
    /// @return epoch the currnet epoch.
    function _currentEpoch() internal view returns (Epoch storage epoch) {
        epoch = _epochs[_epochs.length - 1];
    }

    function _firstEpoch() internal view returns (Epoch storage epoch) {
        epoch = _epochs[0];
    }

    /// @notice Returns the current epoch number.
    /// @return number The 0 based epoch number
    function epochNumber() public view returns (uint256 number) {
        if (_epochs.length == 0) {
            return 0;
        }
        number = _epochs.length - 1;
    }
}
