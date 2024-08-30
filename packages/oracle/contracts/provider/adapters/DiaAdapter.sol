// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

import { Strings } from "@openzeppelin/contracts/utils/Strings.sol";
import { IOracleFeedAdapter } from "./IOracleFeedAdapter.sol";


interface IDiaFeed {
    function getValue (string memory key) external view returns (uint128, uint128);
}

/**
 * @title DiaAdapter
 * @author Segment
 * @notice This oracle fetches price of assets from Dia.
 */
contract DiaAdapter is IOracleFeedAdapter {

    uint8 constant DECIMALS = 8;

    /**
     * @notice Gets the price of a asset from the Dia oracle
     * @param feed Address of the feed
     */
    function getPrice(address feed, bytes memory feedKey) public view returns (uint256 price, uint32 timestamp) {

        string memory key = string(feedKey);
        (uint128 feedPrice, uint128 feedUpdatedAt) = IDiaFeed(feed).getValue(key);

        price = feedPrice * (10 ** (18 - DECIMALS));

        return (price, uint32(feedUpdatedAt));
    }
}
