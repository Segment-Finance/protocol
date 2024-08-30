// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OracleInterface} from "../interfaces/OracleInterface.sol";
import { IOracleFeedAdapter } from "./adapters/IOracleFeedAdapter.sol";


/**
 * @title OracleProvider
 * @author Segment
 * @notice This oracle provider unifies oracle services with adapters.
 */
contract OracleProvider is Ownable, OracleInterface {

    error UnknownAddress(address asset);
    error InvalidPrice(address asset, uint256 price);
    error StalePrice(address asset, uint32 updatedAt);
    error Unauthorized();

    event TokenConfig (address indexed asset);

    struct TTokenConfig {
        /// @notice ERC20 token address
        /// @notice 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE for ETH
        address asset;

        /// @notice Token Adapter
        address adapter;

        /// @notice Adapter parameter - underlying feed
        address feed;

        /// @notice Adapter parameter - underlying key, could be string, bytes32, address; optional
        bytes key;

        /// @notice Price expiration period of this asset
        uint32 maxStalePeriod;

        /// @notice Token decimals
        uint8 tokenDecimals;

        /// @notice  Optionally the underlying asset
        address uAsset;
    }

    /// @notice Token config by assets
    mapping(address => TTokenConfig) public tokens;

    /// @notice Constructor for the implementation contract.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address owner) Ownable(owner) {

    }

    /**
     * @notice Gets the price of an asset from the configured adapter
     * @param asset Address of the asset
     * @return price Price in USD, decimal-place: 18 + (18 - uderlying decimals)
     */
    function getPrice(address asset) public view returns (uint256) {

        (uint256 price, ) = getAdapterPriceInternal(asset, 0);

        uint8 tokenDecimals = tokens[asset].tokenDecimals;
        // Extend the price mantisa, so that the price*amount will be the 36-decimal precision number.
        uint answer = price * (10 ** (18 - tokenDecimals));
        return answer;
    }


    /**
     * @notice Gets the price from the adapter
     * @param asset Address of the asset
     * @param customStalePeriod Optionally, provide additional custom stale period
     */
    function getAdapterPriceInternal (address asset, uint32 customStalePeriod) view internal returns (uint256 price, uint32 timestamp) {
        TTokenConfig memory token = tokens[asset];
        if (token.asset == address(0)) {
            revert UnknownAddress(asset);
        }

        (price, timestamp) = IOracleFeedAdapter(token.adapter).getPrice(token.feed, token.key);
        if (price == 0) {
            revert InvalidPrice(asset, price);
        }

        uint deltaTime = block.timestamp - timestamp;
        if (deltaTime > token.maxStalePeriod || (customStalePeriod > 0 && deltaTime > customStalePeriod)) {
            revert StalePrice(asset, timestamp);
        }

        if (token.uAsset != address(0)) {
            (uint uPrice, ) = getAdapterPriceInternal(token.uAsset, token.maxStalePeriod);
            price = uPrice * price / 10**18;
        }

        return (price, timestamp);
    }

    function updateTokens (TTokenConfig[] memory configs) external onlyOwner {
        for (uint i = 0; i < configs.length; i++) {
            updateTokenInternal(configs[i]);
        }
    }

    function updateTokenInternal (TTokenConfig memory config) internal {
        tokens[config.asset] = config;
        emit TokenConfig(config.asset);
    }
}
