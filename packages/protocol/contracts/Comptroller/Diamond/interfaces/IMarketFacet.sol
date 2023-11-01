// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { SeToken } from "../../../Tokens/SeTokens/SeToken.sol";

interface IMarketFacet {
    function isComptroller() external pure returns (bool);

    function liquidateCalculateSeizeTokens(
        address seTokenBorrowed,
        address seTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256);

    function liquidateSEUSDCalculateSeizeTokens(
        address seTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256);

    function checkMembership(address account, SeToken seToken) external view returns (bool);

    function enterMarkets(address[] calldata seTokens) external returns (uint256[] memory);

    function exitMarket(address seToken) external returns (uint256);

    function _supportMarket(SeToken seToken) external returns (uint256);

    function getAssetsIn(address account) external view returns (SeToken[] memory);

    function getAllMarkets() external view returns (SeToken[] memory);

    function updateDelegate(address delegate, bool allowBorrows) external;
}
