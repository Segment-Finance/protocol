// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

import { IOracleFeedAdapter } from "./IOracleFeedAdapter.sol";


interface IApi3Feed {
    function read () external view returns (int224 price, uint32 updatedAt);
}

/**
 * @title Api3Adapter
 * @author Segment
 * @notice This oracle fetches price of assets from Api3.
 */
contract Api3Adapter is IOracleFeedAdapter {

    uint8 constant DECIMALS = 18;

    /**
     * @notice Gets the price of a asset from the Api3 oracle
     * @param feed Address of the feed
     */
    function getPrice(address feed, bytes memory) public view returns (uint256 price, uint32 timestamp) {

        (int224 feedPrice, uint32 feedUpdatedAt) = IApi3Feed(feed).read();
        require(feedPrice >= 0, "Invalid API3 price");

        price = uint256(uint224(feedPrice));

        return (price, feedUpdatedAt);
    }
}
