// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

/**
 * @title IProtocolShareReserve
 * @author Segment
 * @notice Interface implemented by `ProtocolShareReserve`.
 */
interface IProtocolShareReserve {
    function updateAssetsState(address comptroller, address asset) external;
}
