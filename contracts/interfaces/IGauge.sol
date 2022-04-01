//SPDX-License-Identifier: AGPLv3
pragma solidity ^0.8.9;

interface IGauge {
    function setSnapshot(uint256 _timestamp, uint256 _balance, uint256 _weight) external;
}