// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../Swap/lib/TransferHelper.sol";

interface IPriceOracle {
    function getUnderlyingPrice(ISeToken seToken) external view returns (uint256);
}

interface IComptroller {
    function oracle() external view returns (IPriceOracle);
}

interface ISeToken {
    function borrowBehalf(address borrower, uint256 borrowAmount) external returns (uint256);

    function repayBorrowBehalf(address borrower, uint256 repayAmount) external returns (uint256);

    function borrowBalanceCurrent(address account) external returns (uint256);

    function comptroller() external view returns (IComptroller);

    function underlying() external view returns (address);
}

contract SwapDebtDelegate is Ownable2StepUpgradeable, ReentrancyGuardUpgradeable {
    /// @dev SeToken return value signalling about successful execution
    uint256 internal constant NO_ERROR = 0;

    /// @notice Emitted if debt is swapped successfully
    event DebtSwapped(
        address indexed borrower,
        address indexed seTokenRepaid,
        uint256 repaidAmount,
        address indexed seTokenBorrowed,
        uint256 borrowedAmount
    );

    /// @notice Emitted when the owner transfers tokens, accidentially sent to this contract,
    ///   to their account
    event SweptTokens(address indexed token, uint256 amount);

    /// @notice Thrown if SeTokens' comptrollers are not equal
    error ComptrollerMismatch();

    /// @notice Thrown if repayment fails with an error code
    error RepaymentFailed(uint256 errorCode);

    /// @notice Thrown if borrow fails with an error code
    error BorrowFailed(uint256 errorCode);

    using SafeERC20 for IERC20;

    function initialize() external initializer {
        __Ownable_init_unchained(msg.sender);
        __ReentrancyGuard_init();
    }

    /**
     * @notice Repays a borrow in repayTo.underlying() and borrows borrowFrom.underlying()
     * @param borrower The address of the borrower, whose debt to swap
     * @param repayTo SeToken to repay the debt to
     * @param borrowFrom SeToken to borrow from
     * @param repayAmount The amount to repay in terms of repayTo.underlying()
     */
    function swapDebt(
        address borrower,
        ISeToken repayTo,
        ISeToken borrowFrom,
        uint256 repayAmount
    ) external onlyOwner nonReentrant {
        uint256 actualRepaymentAmount = _repay(repayTo, borrower, repayAmount);
        uint256 amountToBorrow = _convert(repayTo, borrowFrom, actualRepaymentAmount);
        _borrow(borrowFrom, borrower, amountToBorrow);
        emit DebtSwapped(borrower, address(repayTo), actualRepaymentAmount, address(borrowFrom), amountToBorrow);
    }

    /**
     * @notice Transfers tokens, accidentially sent to this contract, to the owner
     * @param token ERC-20 token to sweep
     */
    function sweepTokens(IERC20 token) external onlyOwner {
        uint256 amount = token.balanceOf(address(this));
        token.safeTransfer(owner(), amount);
        emit SweptTokens(address(token), amount);
    }

    /**
     * @dev Transfers the funds from the sender and repays a borrow in seToken on behalf of the borrower
     * @param seToken SeToken to repay the debt to
     * @param borrower The address of the borrower, whose debt to repay
     * @param repayAmount The amount to repay in terms of underlying
     */
    function _repay(
        ISeToken seToken,
        address borrower,
        uint256 repayAmount
    ) internal returns (uint256 actualRepaymentAmount) {
        IERC20 underlying = IERC20(seToken.underlying());
        uint256 balanceBefore = underlying.balanceOf(address(this));
        underlying.safeTransferFrom(msg.sender, address(this), repayAmount);
        uint256 balanceAfter = underlying.balanceOf(address(this));
        uint256 repayAmountMinusFee = balanceAfter - balanceBefore;

        TransferHelper.safeApprove(address(underlying), address(seToken), 0);
        TransferHelper.safeApprove(address(underlying), address(seToken), repayAmountMinusFee);
        uint256 borrowBalanceBefore = seToken.borrowBalanceCurrent(borrower);
        uint256 err = seToken.repayBorrowBehalf(borrower, repayAmountMinusFee);
        if (err != NO_ERROR) {
            revert RepaymentFailed(err);
        }
        uint256 borrowBalanceAfter = seToken.borrowBalanceCurrent(borrower);
        return borrowBalanceBefore - borrowBalanceAfter;
    }

    /**
     * @dev Borrows in seToken on behalf of the borrower and transfers the funds to the sender
     * @param seToken SeToken to borrow from
     * @param borrower The address of the borrower, who will own the borrow
     * @param borrowAmount The amount to borrow in terms of underlying
     */
    function _borrow(ISeToken seToken, address borrower, uint256 borrowAmount) internal {
        IERC20 underlying = IERC20(seToken.underlying());
        uint256 balanceBefore = underlying.balanceOf(address(this));
        uint256 err = seToken.borrowBehalf(borrower, borrowAmount);
        if (err != NO_ERROR) {
            revert BorrowFailed(err);
        }
        uint256 balanceAfter = underlying.balanceOf(address(this));
        uint256 actualBorrowedAmount = balanceAfter - balanceBefore;
        underlying.safeTransfer(msg.sender, actualBorrowedAmount);
    }

    /**
     * @dev Converts the value expressed in convertFrom.underlying() to a value
     *   in convertTo.underlying(), using the oracle price
     * @param convertFrom SeToken to convert from
     * @param convertTo SeToken to convert to
     * @param amount The amount in convertFrom.underlying()
     */
    function _convert(ISeToken convertFrom, ISeToken convertTo, uint256 amount) internal view returns (uint256) {
        IComptroller comptroller = convertFrom.comptroller();
        if (comptroller != convertTo.comptroller()) {
            revert ComptrollerMismatch();
        }
        IPriceOracle oracle = comptroller.oracle();

        // Decimals are accounted for in the oracle contract
        uint256 scaledUsdValue = oracle.getUnderlyingPrice(convertFrom) * amount; // the USD value here has 36 decimals
        return scaledUsdValue / oracle.getUnderlyingPrice(convertTo);
    }
}
