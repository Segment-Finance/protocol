// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { SeToken } from "../../../Tokens/SeTokens/SeToken.sol";

interface IBaseFacet {
    function getSEFAddress() external view returns (address);
}
