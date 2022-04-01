//SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.9;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IveToken } from "../interfaces/IveToken.sol";
import { IGauge } from "../interfaces/IGauge.sol";
import { FixedPointMathLib } from "../lib/FixedPointMathLib.sol";
import { SafeTransferLib } from "../lib/SafeTransferLib.sol";

contract LiquidityGauge is IGauge {

    using FixedPointMathLib for uint256;
    using SafeTransferLib for ERC20;

    /// @notice token to be distributed on this gauge
    ERC20 public rewardsToken;

    /// @notice token that tracks user voting power. 
    /// Used to determine portion of rewards user is entitled to
    IveToken public veToken;

    address public controller;

    /// @notice Keeps track of various snapshot values.
    /// @dev Explain to a developer any extra details
    struct GaugeSnapshot {
        uint256 timestamp;
        uint256 balance;
        uint256 weight;
    }

    /// @notice The current snapshot
    GaugeSnapshot internal snapshot;

    /// @notice Keeps track on if account has claimed rewards in the current epoch.
    /// @dev Mapping: snapshot timestamp => address => claimed.
    mapping(uint256 => mapping(address => bool))public rewardsClaimed;

    modifier onlyController() {
        require(msg.sender == controller, "LG: Only Controller");
        _;
    }

    /// @notice Resets the gauge's current snapshot.
    /// @dev Can only be called by the GaugeController contract.
    function setSnapshot(uint256 _timestamp, uint256 _balance, uint256 _weight) external override onlyController {
        snapshot.timestamp = _timestamp;
        snapshot.balance = _balance;
        snapshot.weight = _weight;
    } 

    /// @notice Claims any pending rewards for the caller from this gauge.
    /// @dev Can only be called at most once successfully per epoch by each caller.
    function claim() public {
        address account = msg.sender;
        require(snapshot.weight != 0 && snapshot.balance != 0 && snapshot.timestamp != 0,
        "LG: Invalid snapshot");
        require(!rewardsClaimed[snapshot.timestamp][account], "Gauge: already claimed");

        rewardsClaimed[snapshot.timestamp][account] = true;
        // get snapshot at point
        // check total tokens available
        // get total votes
        // get user vote share
        // compute token share
        // transfer token share to 
        // share = voting power at snapshot / total votes for gauge
        uint256 vp = veToken.balanceOf(account, snapshot.timestamp);
        // vp / votes for gauge * snapshotBalance
        uint256 portion = vp.mulWadDown(snapshot.weight).divWadDown(snapshot.balance);
        rewardsToken.safeTransfer(account, portion);
    }

    /// @notice Returns this address's current balance of rewards token
    function balance() external view returns (uint256 blnc) {
        blnc = rewardsToken.balanceOf(address(this));
    }

    /// @notice Returns this address's balance of rewards token at the time of the snapshot.
    /// This represents the total amount that can be claimed in this epoch.
    function snapshotBalance() external view returns (uint256) {
        return snapshot.balance;
    }
}
