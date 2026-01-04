// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IDgridPriceFeed {
    function getTDGAITwapPrice18() external view returns (uint256 price18);
}
