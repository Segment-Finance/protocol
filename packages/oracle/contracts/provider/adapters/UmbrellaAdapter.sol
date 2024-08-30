// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

import { IOracleFeedAdapter } from "./IOracleFeedAdapter.sol";


interface IUmbrellaFeeds {
    function getPriceData (bytes32 key) external view returns (uint8 data, uint24 heartbeat, uint32 timestamp, uint128 price);
    function DECIMALS() external view returns (uint8);
}

/**
 * @title UmbrellaAdapter
 * @author Segment
 * @notice This oracle adapter fetches price of assets from Umbrella.
 */
contract UmbrellaAdapter is IOracleFeedAdapter {

    /**
     * @notice Gets the price of a asset from the Umbrella oracle
     * @param feed Address of the feed
     * @param feedKey Umbrella's feed key
     */
    function getPrice(address feed, bytes memory feedKey) public view returns (uint256 price, uint32 timestamp) {

        (, , uint32 feedTimestamp, uint128 feedPrice) = IUmbrellaFeeds(feed).getPriceData(bytes32(feedKey));

        uint8 decimals = IUmbrellaFeeds(feed).DECIMALS();

        price = uint256(feedPrice) * 10**(18 - decimals);
        return (price, feedTimestamp);
    }
}
