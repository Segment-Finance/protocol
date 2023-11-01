pragma solidity ^0.8.20;

import "../Tokens/SeTokens/SeToken.sol";
import "../../../oracle/contracts/PriceOracle.sol";
import "../Tokens/SEUSD/SEUSDControllerInterface.sol";

abstract contract ComptrollerInterface {
    /// @notice Indicator that this is a Comptroller contract (for inspection)
    bool public constant isComptroller = true;

    /*** Assets You Are In ***/

    function enterMarkets(address[] calldata seTokens) virtual external returns (uint[] memory);

    function exitMarket(address seToken) virtual external returns (uint);

    /*** Policy Hooks ***/

    function mintAllowed(address seToken, address minter, uint mintAmount) virtual external returns (uint);

    function mintVerify(address seToken, address minter, uint mintAmount, uint mintTokens) virtual external;

    function redeemAllowed(address seToken, address redeemer, uint redeemTokens) virtual external returns (uint);

    function redeemVerify(address seToken, address redeemer, uint redeemAmount, uint redeemTokens) virtual external;

    function borrowAllowed(address seToken, address borrower, uint borrowAmount) virtual external returns (uint);

    function borrowVerify(address seToken, address borrower, uint borrowAmount) virtual external;

    function repayBorrowAllowed(
        address seToken,
        address payer,
        address borrower,
        uint repayAmount
    ) virtual external returns (uint);

    function repayBorrowVerify(
        address seToken,
        address payer,
        address borrower,
        uint repayAmount,
        uint borrowerIndex
    ) virtual external;

    function liquidateBorrowAllowed(
        address seTokenBorrowed,
        address seTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount
    ) virtual external returns (uint);

    function liquidateBorrowVerify(
        address seTokenBorrowed,
        address seTokenCollateral,
        address liquidator,
        address borrower,
        uint repayAmount,
        uint seizeTokens
    ) virtual external;

    function seizeAllowed(
        address seTokenCollateral,
        address seTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) virtual external returns (uint);

    function seizeVerify(
        address seTokenCollateral,
        address seTokenBorrowed,
        address liquidator,
        address borrower,
        uint seizeTokens
    ) virtual external;

    function transferAllowed(address seToken, address src, address dst, uint transferTokens) virtual external returns (uint);

    function transferVerify(address seToken, address src, address dst, uint transferTokens) virtual external;

    /*** Liquidity/Liquidation Calculations ***/

    function liquidateCalculateSeizeTokens(
        address seTokenBorrowed,
        address seTokenCollateral,
        uint repayAmount
    ) virtual external view returns (uint, uint);

    function setMintedSEUSDOf(address owner, uint amount) virtual external returns (uint);

    function liquidateSEUSDCalculateSeizeTokens(
        address seTokenCollateral,
        uint repayAmount
    ) virtual external view returns (uint, uint);

    function getSEFAddress() virtual public view returns (address);

    function markets(address) virtual external view returns (bool, uint);

    function oracle() virtual external view returns (PriceOracle);

    function getAccountLiquidity(address) virtual external view returns (uint, uint, uint);

    function getAssetsIn(address) virtual external view returns (SeToken[] memory);

    function claimSegment(address) virtual external;

    function segmentAccrued(address) virtual external view returns (uint);

    function segmentSupplySpeeds(address) virtual external view returns (uint);

    function segmentBorrowSpeeds(address) virtual external view returns (uint);

    function getAllMarkets() virtual external view returns (SeToken[] memory);

    function segmentSupplierIndex(address, address) virtual external view returns (uint);

    function segmentInitialIndex() virtual external view returns (uint224);

    function segmentBorrowerIndex(address, address) virtual external view returns (uint);

    function segmentBorrowState(address) virtual external view returns (uint224, uint32);

    function segmentSupplyState(address) virtual external view returns (uint224, uint32);

    function approvedDelegates(address borrower, address delegate) virtual external view returns (bool);

    function seusdController() virtual external view returns (SEUSDControllerInterface);

    function liquidationIncentiveMantissa() virtual external view returns (uint);

    function protocolPaused() virtual external view returns (bool);

    function mintedSEUSDs(address user) virtual external view returns (uint);

    function seusdMintRate() virtual external view returns (uint);
}

interface ISEUSDVault {
    function updatePendingRewards() external;
}

interface IComptroller {
    function liquidationIncentiveMantissa() external view returns (uint);

    /*** Treasury Data ***/
    function treasuryAddress() external view returns (address);

    function treasuryPercent() external view returns (uint);
}
