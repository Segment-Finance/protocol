// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

import { ResilientOracleInterface } from "../../oracle/contracts/interfaces/OracleInterface.sol";

import { SeToken } from "./SeToken.sol";
import { RewardsDistributor } from "./Rewards/RewardsDistributor.sol";

/**
 * @title ComptrollerInterface
 * @author Segment
 * @notice Interface implemented by the `Comptroller` contract.
 */
interface ComptrollerInterface {
    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata seTokens) external returns (uint256[] memory);

    function exitMarket(address seToken) external returns (uint256);

    /*** Policy Hooks ***/

    function preMintHook(address seToken, address minter, uint256 mintAmount) external;

    function preRedeemHook(address seToken, address redeemer, uint256 redeemTokens) external;

    function preBorrowHook(address seToken, address borrower, uint256 borrowAmount) external;

    function preRepayHook(address seToken, address borrower) external;

    function preLiquidateHook(
        address seTokenBorrowed,
        address seTokenCollateral,
        address borrower,
        uint256 repayAmount,
        bool skipLiquidityCheck
    ) external;

    function preSeizeHook(
        address seTokenCollateral,
        address seTokenBorrowed,
        address liquidator,
        address borrower
    ) external;

    function preTransferHook(address seToken, address src, address dst, uint256 transferTokens) external;

    function isComptroller() external view returns (bool);

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address seTokenBorrowed,
        address seTokenCollateral,
        uint256 repayAmount
    ) external view returns (uint256, uint256);

    function getAllMarkets() external view returns (SeToken[] memory);
}

/**
 * @title ComptrollerViewInterface
 * @author Segment
 * @notice Interface implemented by the `Comptroller` contract, including only some util view functions.
 */
interface ComptrollerViewInterface {
    function markets(address) external view returns (bool, uint256);

    function oracle() external view returns (ResilientOracleInterface);

    function getAssetsIn(address) external view returns (SeToken[] memory);

    function closeFactorMantissa() external view returns (uint256);

    function liquidationIncentiveMantissa() external view returns (uint256);

    function minLiquidatableCollateral() external view returns (uint256);

    function getRewardDistributors() external view returns (RewardsDistributor[] memory);

    function getAllMarkets() external view returns (SeToken[] memory);

    function borrowCaps(address) external view returns (uint256);

    function supplyCaps(address) external view returns (uint256);
}
