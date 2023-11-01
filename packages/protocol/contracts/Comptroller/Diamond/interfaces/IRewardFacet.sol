// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { SeToken } from "../../../Tokens/SeTokens/SeToken.sol";
import { ComptrollerV14Storage } from "../../ComptrollerStorage.sol";

interface IRewardFacet {
    function claimSegment(address holder) external;

    function claimSegment(address holder, SeToken[] calldata seTokens) external;

    function claimSegment(address[] calldata holders, SeToken[] calldata seTokens, bool borrowers, bool suppliers) external;

    function claimSegmentAsCollateral(address holder) external;

    function _grantSEF(address recipient, uint256 amount) external;

    function claimSegment(
        address[] calldata holders,
        SeToken[] calldata seTokens,
        bool borrowers,
        bool suppliers,
        bool collateral
    ) external;
}
