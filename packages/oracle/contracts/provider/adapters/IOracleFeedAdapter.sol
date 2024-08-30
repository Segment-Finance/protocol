// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;


interface IOracleFeedAdapter {
    function getPrice (address feed, bytes memory feedKey) external view returns (uint256 price, uint32 timestamp);
}
