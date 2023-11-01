// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { PriceOracle } from "../../../../../oracle/contracts/PriceOracle.sol";
import { SeToken } from "../../../Tokens/SeTokens/SeToken.sol";
import { ComptrollerV14Storage } from "../../ComptrollerStorage.sol";
import { SEUSDControllerInterface } from "../../../Tokens/SEUSD/SEUSDController.sol";
import { ComptrollerLensInterface } from "../../../Comptroller/ComptrollerLensInterface.sol";

interface ISetterFacet {
    function _setPriceOracle(PriceOracle newOracle) external returns (uint256);

    function _setCloseFactor(uint256 newCloseFactorMantissa) external returns (uint256);

    function _setAccessControl(address newAccessControlAddress) external returns (uint256);

    function _setCollateralFactor(SeToken seToken, uint256 newCollateralFactorMantissa) external returns (uint256);

    function _setLiquidationIncentive(uint256 newLiquidationIncentiveMantissa) external returns (uint256);

    function _setLiquidatorContract(address newLiquidatorContract_) external;

    function _setPauseGuardian(address newPauseGuardian) external returns (uint256);

    function _setMarketBorrowCaps(SeToken[] calldata seTokens, uint256[] calldata newBorrowCaps) external;

    function _setMarketSupplyCaps(SeToken[] calldata seTokens, uint256[] calldata newSupplyCaps) external;

    function _setProtocolPaused(bool state) external returns (bool);

    function _setActionsPaused(
        address[] calldata markets,
        ComptrollerV14Storage.Action[] calldata actions,
        bool paused
    ) external;

    function _setSEUSDController(SEUSDControllerInterface seusdController_) external returns (uint256);

    function _setSEUSDMintRate(uint256 newSEUSDMintRate) external returns (uint256);

    function setMintedSEUSDOf(address owner, uint256 amount) external returns (uint256);

    function _setTreasuryData(
        address newTreasuryGuardian,
        address newTreasuryAddress,
        uint256 newTreasuryPercent
    ) external returns (uint256);

    function _setComptrollerLens(ComptrollerLensInterface comptrollerLens_) external returns (uint256);

    function _setSegmentSEUSDVaultRate(uint256 segmentSEUSDVaultRate_) external;

    function _setSEUSDVaultInfo(address vault_, uint256 releaseStartBlock_, uint256 minReleaseAmount_) external;

    function _setForcedLiquidation(address seToken, bool enable) external;

    function _setSEFAddress(address sefToken) external;
    function _setSeSEFAddress(address seSefToken) external;
}
