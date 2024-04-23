// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OracleInterface} from "../interfaces/OracleInterface.sol";


interface IDiaOracle {
    function getValue (string memory key) external view returns (uint128, uint128);
}

/**
 * @title DiaOracle
 * @author Segment
 * @notice This oracle fetches price of assets from DIA.
 */
contract DiaOracle is Ownable, OracleInterface {

    error UnknownAddress(address asset);
    error InvalidPrice(address asset, uint128 price);
    error StalePrice(address asset, uint128 updatedAt);

    event TokenConfig (address asset);

    struct TTokenConfig {
        /// @notice ERC20 token address
        /// @notice 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE for ETH
        address asset;
        /// @notice Chainlink feed address
        string key;
        /// @notice Price expiration period of this asset
        uint64 maxStalePeriod;

        /// @notice Decimals returned by DiaOracle (usually 8)
        uint64 feedDecimals;

        /// @notice Token decimals
        uint64 tokenDecimals;

        /// @notice  Optionally the next hop towards USD
        address route;
    }

    IDiaOracle public dia;

    /// @notice Token config by assets
    mapping(address => TTokenConfig) public tokens;

    /// @notice Constructor for the implementation contract.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address owner, IDiaOracle _dia) Ownable(owner) {
        dia = _dia;
    }

    /**
     * @notice Gets the price of a asset from the DIA oracle
     * @param asset Address of the asset
     * @return Price in USD
     */
    function getPrice(address asset) public view returns (uint256) {
        TTokenConfig memory token = tokens[asset];
        if (token.asset == address(0)) {
            revert UnknownAddress(asset);
        }

        (uint128 price, uint128 updatedAt) = dia.getValue(token.key);
        if (price == 0) {
            revert InvalidPrice(asset, price);
        }

        uint deltaTime = block.timestamp - updatedAt;
        if (deltaTime > token.maxStalePeriod) {
            revert StalePrice(asset, updatedAt);
        }

        uint feedDecimals = token.feedDecimals;
        uint tokenDecimals = token.tokenDecimals;
        uint answer = (uint256(price) * (10 ** (18 - feedDecimals))) * (10 ** (18 - tokenDecimals));

        if (token.route != address(0)) {
            uint uPrice = getPrice(token.route);
            answer = uPrice * answer / 10**18;
        }

        return answer;
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
