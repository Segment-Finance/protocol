pragma solidity ^0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ISeToken is IERC20 {}

interface ISeBep20 is ISeToken {
    function underlying() external view returns (address);

    function liquidateBorrow(
        address borrower,
        uint256 repayAmount,
        ISeToken seTokenCollateral
    ) external returns (uint256);
}

interface ISeBNB is ISeToken {
    function liquidateBorrow(address borrower, ISeToken seTokenCollateral) external payable;
}

interface ISEUSDController {
    function liquidateSEUSD(
        address borrower,
        uint256 repayAmount,
        ISeToken seTokenCollateral
    ) external returns (uint256, uint256);

    function getSEUSDAddress() external view returns (address);
}

interface IComptroller {
    function liquidationIncentiveMantissa() external view returns (uint256);

    function seusdController() external view returns (ISEUSDController);
}
