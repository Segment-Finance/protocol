// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { SeToken } from "../../../Tokens/SeTokens/SeToken.sol";

interface IPolicyFacet {
    function mintAllowed(address seToken, address minter, uint256 mintAmount) external returns (uint256);

    function mintVerify(address seToken, address minter, uint256 mintAmount, uint256 mintTokens) external;

    function redeemAllowed(address seToken, address redeemer, uint256 redeemTokens) external returns (uint256);

    function redeemVerify(address seToken, address redeemer, uint256 redeemAmount, uint256 redeemTokens) external pure;

    function borrowAllowed(address seToken, address borrower, uint256 borrowAmount) external returns (uint256);

    function borrowVerify(address seToken, address borrower, uint256 borrowAmount) external;

    function repayBorrowAllowed(
        address seToken,
        address payer,
        address borrower,
        uint256 repayAmount
    ) external returns (uint256);

    function repayBorrowVerify(
        address seToken,
        address payer,
        address borrower,
        uint256 repayAmount,
        uint256 borrowerIndex
    ) external;

    function liquidateBorrowAllowed(
        address seTokenBorrowed,
        address seTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external view returns (uint256);

    function liquidateBorrowVerify(
        address seTokenBorrowed,
        address seTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount,
        uint256 seizeTokens
    ) external;

    function seizeAllowed(
        address seTokenCollateral,
        address seTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external returns (uint256);

    function seizeVerify(
        address seTokenCollateral,
        address seTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external;

    function transferAllowed(
        address seToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external returns (uint256);

    function transferVerify(address seToken, address src, address dst, uint256 transferTokens) external;

    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256);

    function getHypotheticalAccountLiquidity(
        address account,
        address seTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) external view returns (uint256, uint256, uint256);

    function _setSegmentSpeeds(
        SeToken[] calldata seTokens,
        uint256[] calldata supplySpeeds,
        uint256[] calldata borrowSpeeds
    ) external;
}
