pragma solidity ^0.8.20;

import "../../protocol/contracts/Tokens/SeTokens/SeToken.sol";

abstract contract PriceOracle {
    /// @notice Indicator that this is a PriceOracle contract (for inspection)
    bool public constant isPriceOracle = true;

    /**
     * @notice Get the underlying price of a seToken asset
     * @param seToken The seToken to get the underlying price of
     * @return The underlying asset price mantissa (scaled by 1e18).
     *  Zero means the price is unavailable.
     */
    function getUnderlyingPrice(SeToken seToken) virtual external view returns (uint);
}
