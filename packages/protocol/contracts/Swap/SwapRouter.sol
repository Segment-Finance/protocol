// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./interfaces/IPancakeSwapV2Router.sol";
import "./interfaces/ISeToken.sol";
import "./RouterHelper.sol";
import "./interfaces/ISeBNB.sol";
import "./interfaces/ISeToken.sol";
import "./interfaces/InterfaceComptroller.sol";
import "./lib/TransferHelper.sol";

/**
 * @title Segment's Pancake Swap Integration Contract
 * @notice This contracts allows users to swap a token for another one and supply/repay with the latter.
 * @dev For all functions that do not swap native BNB, user must approve this contract with the amount, prior the calling the swap function.
 * @author 0xlucian
 */

contract SwapRouter is Ownable2Step, RouterHelper, IPancakeSwapV2Router {
    using SafeERC20 for IERC20;

    address public immutable comptrollerAddress;

    uint256 private constant _NOT_ENTERED = 1;

    uint256 private constant _ENTERED = 2;

    address public seBNBAddress;

    /**
     * @dev Guard variable for re-entrancy checks
     */
    uint256 internal _status;

    // ***************
    // ** MODIFIERS **
    // ***************
    modifier ensure(uint256 deadline) {
        if (deadline < block.timestamp) {
            revert SwapDeadlineExpire(deadline, block.timestamp);
        }
        _;
    }

    modifier ensurePath(address[] calldata path) {
        if (path.length < 2) {
            revert InvalidPath();
        }
        _;
    }

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        if (_status == _ENTERED) {
            revert ReentrantCheck();
        }
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    /// @notice event emitted on sweep token success
    event SweepToken(address indexed token, address indexed to, uint256 sweepAmount);

    /// @notice event emitted on seBNBAddress update
    event VBNBAddressUpdated(address indexed oldAddress, address indexed newAddress);

    // *********************
    // **** CONSTRUCTOR ****
    // *********************

    /// @notice Constructor for the implementation contract. Sets immutable variables.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address WBNB_,
        address factory_,
        address _comptrollerAddress,
        address _seBNBAddress
    ) RouterHelper(WBNB_, factory_) Ownable(_msgSender()) {
        if (_comptrollerAddress == address(0) || _seBNBAddress == address(0)) {
            revert ZeroAddress();
        }
        comptrollerAddress = _comptrollerAddress;
        _status = _NOT_ENTERED;
        seBNBAddress = _seBNBAddress;
    }

    receive() external payable {
        assert(msg.sender == WBNB); // only accept BNB via fallback from the WBNB contract
    }

    // ****************************
    // **** EXTERNAL FUNCTIONS ****
    // ****************************

    /**
     * @notice Setter for the seBNB address.
     * @param _seBNBAddress Address of the BNB seToken to update.
     */
    function setVBNBAddress(address _seBNBAddress) external onlyOwner {
        if (_seBNBAddress == address(0)) {
            revert ZeroAddress();
        }

        _isSeTokenListed(_seBNBAddress);

        address oldAddress = seBNBAddress;
        seBNBAddress = _seBNBAddress;

        emit VBNBAddressUpdated(oldAddress, seBNBAddress);
    }

    /**
     * @notice Swap token A for token B and supply to a Segment market
     * @param seTokenAddress The address of the seToken contract for supplying assets.
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     */
    function swapExactTokensForTokensAndSupply(
        address seTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureSeTokenChecks(seTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _supply(lastAsset, seTokenAddress, swapAmount);
    }

    /**
     * @notice Swap deflationary (a small amount of fee is deducted at the time of transfer of token) token A for token B and supply to a Segment market.
     * @param seTokenAddress The address of the seToken contract for supplying assets.
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     */
    function swapExactTokensForTokensAndSupplyAtSupportingFee(
        address seTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureSeTokenChecks(seTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, address(this));
        _supply(lastAsset, seTokenAddress, swapAmount);
    }

    /**
     * @notice Swap BNB for another token and supply to a Segment market
     * @dev The amount to be swapped is obtained from the msg.value, since we are swapping BNB
     * @param seTokenAddress The address of the seToken contract for supplying assets.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapExactBNBForTokensAndSupply(
        address seTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureSeTokenChecks(seTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactBNBForTokens(amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _supply(lastAsset, seTokenAddress, swapAmount);
    }

    /**
     * @notice Swap BNB for another deflationary token (a small amount of fee is deducted at the time of transfer of token) and supply to a Segment market
     * @dev The amount to be swapped is obtained from the msg.value, since we are swapping BNB
     * @param seTokenAddress The address of the seToken contract for supplying assets.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapExactBNBForTokensAndSupplyAtSupportingFee(
        address seTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureSeTokenChecks(seTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactBNBForTokens(amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, address(this));
        _supply(lastAsset, seTokenAddress, swapAmount);
    }

    /**
     * @notice Swap tokens for Exact tokens and supply to a Segment market
     * @param seTokenAddress The address of the seToken contract for supplying assets.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapTokensForExactTokensAndSupply(
        address seTokenAddress,
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureSeTokenChecks(seTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapTokensForExactTokens(amountOut, amountInMax, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _supply(lastAsset, seTokenAddress, swapAmount);
    }

    /**
     * @notice Swap BNB for Exact tokens and supply to a Segment market
     * @param seTokenAddress The address of the seToken contract for supplying assets.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapBNBForExactTokensAndSupply(
        address seTokenAddress,
        uint256 amountOut,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureSeTokenChecks(seTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapBNBForExactTokens(amountOut, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _supply(lastAsset, seTokenAddress, swapAmount);
    }

    /**
     * @notice Swap Exact tokens for BNB and supply to a Segment market
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapExactTokensForBNBAndSupply(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapExactTokensForBNB(amountIn, amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        _mintVBNBandTransfer(swapAmount);
    }

    /**
     * @notice Swap Exact deflationary tokens (a small amount of fee is deducted at the time of transfer of tokens) for BNB and supply to a Segment market
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapExactTokensForBNBAndSupplyAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapExactTokensForBNB(amountIn, amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        if (swapAmount < amountOutMin) {
            revert SwapAmountLessThanAmountOutMin(swapAmount, amountOutMin);
        }
        _mintVBNBandTransfer(swapAmount);
    }

    /**
     * @notice Swap tokens for Exact BNB and supply to a Segment market
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapTokensForExactBNBAndSupply(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapTokensForExactBNB(amountOut, amountInMax, path, address(this));
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        _mintVBNBandTransfer(swapAmount);
    }

    /**
     * @notice Swap token A for token B and repay a borrow from a Segment market
     * @param seTokenAddress The address of the seToken contract to repay.
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive (and repay)
     */
    function swapExactTokensForTokensAndRepay(
        address seTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureSeTokenChecks(seTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, seTokenAddress, swapAmount);
    }

    /**
     * @notice Swap deflationary token (a small amount of fee is deducted at the time of transfer of token) token A for token B and repay a borrow from a Segment market
     * @param seTokenAddress The address of the seToken contract to repay.
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive (and repay)
     */
    function swapExactTokensForTokensAndRepayAtSupportingFee(
        address seTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureSeTokenChecks(seTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactTokensForTokens(amountIn, amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, address(this));
        _repay(lastAsset, seTokenAddress, swapAmount);
    }

    /**
     * @notice Swap BNB for another token and repay a borrow from a Segment market
     * @dev The amount to be swapped is obtained from the msg.value, since we are swapping BNB
     * @param seTokenAddress The address of the seToken contract to repay.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered so the swap path tokens are listed first and last asset is the token we receive
     */
    function swapExactBNBForTokensAndRepay(
        address seTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureSeTokenChecks(seTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactBNBForTokens(amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, seTokenAddress, swapAmount);
    }

    /**
     * @notice Swap BNB for another deflationary token (a small amount of fee is deducted at the time of transfer of token) and repay a borrow from a Segment market
     * @dev The amount to be swapped is obtained from the msg.value, since we are swapping BNB
     * @param seTokenAddress The address of the seToken contract to repay.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered so the swap path tokens are listed first and last asset is the token we receive
     */
    function swapExactBNBForTokensAndRepayAtSupportingFee(
        address seTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureSeTokenChecks(seTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapExactBNBForTokens(amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, address(this));
        _repay(lastAsset, seTokenAddress, swapAmount);
    }

    /**
     * @notice Swap tokens for Exact tokens and repay to a Segment market
     * @param seTokenAddress The address of the seToken contract for supplying assets.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapTokensForExactTokensAndRepay(
        address seTokenAddress,
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureSeTokenChecks(seTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapTokensForExactTokens(amountOut, amountInMax, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, seTokenAddress, swapAmount);
    }

    /**
     * @notice Swap tokens for full tokens debt and repay to a Segment market
     * @param seTokenAddress The address of the seToken contract for supplying assets.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapTokensForFullTokenDebtAndRepay(
        address seTokenAddress,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureSeTokenChecks(seTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        uint256 amountOut = ISeToken(seTokenAddress).borrowBalanceCurrent(msg.sender);
        _swapTokensForExactTokens(amountOut, amountInMax, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, seTokenAddress, swapAmount);
    }

    /**
     * @notice Swap BNB for Exact tokens and repay to a Segment market
     * @param seTokenAddress The address of the seToken contract for supplying assets.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapBNBForExactTokensAndRepay(
        address seTokenAddress,
        uint256 amountOut,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureSeTokenChecks(seTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        _swapBNBForExactTokens(amountOut, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, seTokenAddress, swapAmount);
    }

    /**
     * @notice Swap BNB for Exact tokens and repay to a Segment market
     * @param seTokenAddress The address of the seToken contract for supplying assets.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapBNBForFullTokenDebtAndRepay(
        address seTokenAddress,
        address[] calldata path,
        uint256 deadline
    ) external payable override nonReentrant ensure(deadline) ensurePath(path) {
        _ensureSeTokenChecks(seTokenAddress, path[path.length - 1]);
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(address(this));
        uint256 amountOut = ISeToken(seTokenAddress).borrowBalanceCurrent(msg.sender);
        _swapBNBForExactTokens(amountOut, path, address(this));
        uint256 swapAmount = _getSwapAmount(lastAsset, balanceBefore);
        _repay(lastAsset, seTokenAddress, swapAmount);
    }

    /**
     * @notice Swap Exact tokens for BNB and repay to a Segment market
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapExactTokensForBNBAndRepay(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapExactTokensForBNB(amountIn, amountOutMin, path, address(this), TypesOfTokens.NON_SUPPORTING_FEE);
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        ISeBNB(seBNBAddress).repayBorrowBehalf{ value: swapAmount }(msg.sender);
    }

    /**
     * @notice Swap Exact deflationary tokens (a small amount of fee is deducted at the time of transfer of tokens) for BNB and repay to a Segment market
     * @param amountIn The amount of tokens to swap.
     * @param amountOutMin Minimum amount of tokens to receive.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapExactTokensForBNBAndRepayAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapExactTokensForBNB(amountIn, amountOutMin, path, address(this), TypesOfTokens.SUPPORTING_FEE);
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        if (swapAmount < amountOutMin) {
            revert SwapAmountLessThanAmountOutMin(swapAmount, amountOutMin);
        }
        ISeBNB(seBNBAddress).repayBorrowBehalf{ value: swapAmount }(msg.sender);
    }

    /**
     * @notice Swap tokens for Exact BNB and repay to a Segment market
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapTokensForExactBNBAndRepay(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        _swapTokensForExactBNB(amountOut, amountInMax, path, address(this));
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        ISeBNB(seBNBAddress).repayBorrowBehalf{ value: swapAmount }(msg.sender);
    }

    /**
     * @notice Swap tokens for Exact BNB and repay to a Segment market
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param deadline Unix timestamp after which the transaction will revert.
     * @dev Addresses of underlying assets should be ordered that first asset is the token we are swapping and second asset is the token we receive
     * @dev In case of swapping native BNB the first asset in path array should be the wBNB address
     */
    function swapTokensForFullBNBDebtAndRepay(
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) {
        uint256 balanceBefore = address(this).balance;
        uint256 amountOut = ISeToken(seBNBAddress).borrowBalanceCurrent(msg.sender);
        _swapTokensForExactBNB(amountOut, amountInMax, path, address(this));
        uint256 balanceAfter = address(this).balance;
        uint256 swapAmount = balanceAfter - balanceBefore;
        ISeBNB(seBNBAddress).repayBorrowBehalf{ value: swapAmount }(msg.sender);
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output tokens as possible,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output token, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountIn The address of the seToken contract to repay.
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256[] memory amounts) {
        amounts = _swapExactTokensForTokens(amountIn, amountOutMin, path, to, TypesOfTokens.NON_SUPPORTING_FEE);
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output tokens as possible,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output token, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     *         This method to swap deflationary tokens which would require supporting fee.
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountIn The address of the seToken contract to repay.
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactTokensForTokensAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256 swapAmount) {
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(to);
        _swapExactTokensForTokens(amountIn, amountOutMin, path, to, TypesOfTokens.SUPPORTING_FEE);
        swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, to);
    }

    /**
     * @notice Swaps an exact amount of BNB for as many output tokens as possible,
     *         along the route determined by the path. The first element of path must be WBNB,
     *         the last is the output token, and any intermediate elements represent
     *         intermediate pairs to trade through (if, for example, a direct pair does not exist).
     * @dev amountIn is passed through the msg.value of the transaction
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactBNBForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        payable
        virtual
        override
        nonReentrant
        ensure(deadline)
        ensurePath(path)
        returns (uint256[] memory amounts)
    {
        amounts = _swapExactBNBForTokens(amountOutMin, path, to, TypesOfTokens.NON_SUPPORTING_FEE);
    }

    /**
     * @notice Swaps an exact amount of ETH for as many output tokens as possible,
     *         along the route determined by the path. The first element of path must be WBNB,
     *         the last is the output token, and any intermediate elements represent
     *         intermediate pairs to trade through (if, for example, a direct pair does not exist).
     *         This method to swap deflationary tokens which would require supporting fee.
     * @dev amountIn is passed through the msg.value of the transaction
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactBNBForTokensAtSupportingFee(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256 swapAmount) {
        address lastAsset = path[path.length - 1];
        uint256 balanceBefore = IERC20(lastAsset).balanceOf(to);
        _swapExactBNBForTokens(amountOutMin, path, to, TypesOfTokens.SUPPORTING_FEE);
        swapAmount = _checkForAmountOut(lastAsset, balanceBefore, amountOutMin, to);
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output ETH as possible,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output ETH, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountIn The address of the seToken contract to repay.
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactTokensForBNB(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) returns (uint256[] memory amounts) {
        amounts = _swapExactTokensForBNB(amountIn, amountOutMin, path, to, TypesOfTokens.NON_SUPPORTING_FEE);
    }

    /**
     * @notice Swaps an exact amount of input tokens for as many output ETH as possible,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output ETH, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     *         This method to swap deflationary tokens which would require supporting fee.
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountIn The address of the seToken contract to repay.
     * @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     */
    function swapExactTokensForBNBAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override nonReentrant ensure(deadline) ensurePath(path) returns (uint256 swapAmount) {
        uint256 balanceBefore = to.balance;
        _swapExactTokensForBNB(amountIn, amountOutMin, path, to, TypesOfTokens.SUPPORTING_FEE);
        uint256 balanceAfter = to.balance;
        swapAmount = balanceAfter - balanceBefore;
        if (swapAmount < amountOutMin) {
            revert SwapAmountLessThanAmountOutMin(swapAmount, amountOutMin);
        }
    }

    /**
     * @notice Swaps an as many amount of input tokens for as exact amount of tokens as output,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output token, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     **/
    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256[] memory amounts) {
        amounts = _swapTokensForExactTokens(amountOut, amountInMax, path, to);
    }

    /**
     * @notice Swaps an as ETH as input tokens for as exact amount of tokens as output,
     *         along the route determined by the path. The first element of path is the input WBNB,
     *         the last is the output as token, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     **/
    function swapBNBForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    )
        external
        payable
        virtual
        override
        nonReentrant
        ensure(deadline)
        ensurePath(path)
        returns (uint256[] memory amounts)
    {
        amounts = _swapBNBForExactTokens(amountOut, path, to);
    }

    /**
     * @notice Swaps an as many amount of input tokens for as exact amount of ETH as output,
     *         along the route determined by the path. The first element of path is the input token,
     *         the last is the output as ETH, and any intermediate elements represent intermediate
     *         pairs to trade through (if, for example, a direct pair does not exist).
     * @dev msg.sender should have already given the router an allowance of at least amountIn on the input token.
     * @param amountOut The amount of the tokens needs to be as output token.
     * @param amountInMax The maximum amount of input tokens that can be taken for the transaction not to revert.
     * @param path Array with addresses of the underlying assets to be swapped
     * @param to Recipient of the output tokens.
     * @param deadline Unix timestamp after which the transaction will revert.
     **/
    function swapTokensForExactBNB(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external virtual override nonReentrant ensure(deadline) ensurePath(path) returns (uint256[] memory amounts) {
        amounts = _swapTokensForExactBNB(amountOut, amountInMax, path, to);
    }

    /**
     * @notice A public function to sweep accidental BEP-20 transfers to this contract. Tokens are sent to the address `to`, provided in input
     * @param token The address of the ERC-20 token to sweep
     * @param to Recipient of the output tokens.
     * @param sweepAmount The ampunt of the tokens to sweep
     * @custom:access Only Governance
     */
    function sweepToken(IERC20 token, address to, uint256 sweepAmount) external onlyOwner nonReentrant {
        if (to == address(0)) {
            revert ZeroAddress();
        }
        uint256 balance = token.balanceOf(address(this));
        if (sweepAmount > balance) {
            revert InsufficientBalance(sweepAmount, balance);
        }
        token.safeTransfer(to, sweepAmount);

        emit SweepToken(address(token), to, sweepAmount);
    }

    /**
     * @notice Supply token to a Segment market
     * @param path The addresses of the underlying token
     * @param seTokenAddress The address of the seToken contract for supplying assets.
     * @param swapAmount The amount of tokens supply to Segment Market.
     */
    function _supply(address path, address seTokenAddress, uint256 swapAmount) internal {
        TransferHelper.safeApprove(path, seTokenAddress, 0);
        TransferHelper.safeApprove(path, seTokenAddress, swapAmount);
        uint256 response = ISeToken(seTokenAddress).mintBehalf(msg.sender, swapAmount);
        if (response != 0) {
            revert SupplyError(msg.sender, seTokenAddress, response);
        }
    }

    /**
     * @notice Repay a borrow from Segment market
     * @param path The addresses of the underlying token
     * @param seTokenAddress The address of the seToken contract for supplying assets.
     * @param swapAmount The amount of tokens repay to Segment Market.
     */
    function _repay(address path, address seTokenAddress, uint256 swapAmount) internal {
        TransferHelper.safeApprove(path, seTokenAddress, 0);
        TransferHelper.safeApprove(path, seTokenAddress, swapAmount);
        uint256 response = ISeToken(seTokenAddress).repayBorrowBehalf(msg.sender, swapAmount);
        if (response != 0) {
            revert RepayError(msg.sender, seTokenAddress, response);
        }
    }

    /**
     * @notice Check if the balance of to minus the balanceBefore is greater or equal to the amountOutMin.
     * @param asset The address of the underlying token
     * @param balanceBefore Balance before the swap.
     * @param amountOutMin Min amount out threshold.
     * @param to Recipient of the output tokens.
     */
    function _checkForAmountOut(
        address asset,
        uint256 balanceBefore,
        uint256 amountOutMin,
        address to
    ) internal view returns (uint256 swapAmount) {
        uint256 balanceAfter = IERC20(asset).balanceOf(to);
        swapAmount = balanceAfter - balanceBefore;
        if (swapAmount < amountOutMin) {
            revert SwapAmountLessThanAmountOutMin(swapAmount, amountOutMin);
        }
    }

    /**
     * @notice Returns the difference between the balance of this and the balanceBefore
     * @param asset The address of the underlying token
     * @param balanceBefore Balance before the swap.
     */
    function _getSwapAmount(address asset, uint256 balanceBefore) internal view returns (uint256 swapAmount) {
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        swapAmount = balanceAfter - balanceBefore;
    }

    /**
     * @notice Check isSeTokenListed and last address in the path should be seToken underlying.
     * @param seTokenAddress Address of the seToken.
     * @param underlying Address of the underlying asset.
     */
    function _ensureSeTokenChecks(address seTokenAddress, address underlying) internal {
        _isSeTokenListed(seTokenAddress);
        if (ISeToken(seTokenAddress).underlying() != underlying) {
            revert SeTokenUnderlyingInvalid(underlying);
        }
    }

    /**
     * @notice Check is seToken listed in the pool.
     * @param seToken Address of the seToken.
     */
    function _isSeTokenListed(address seToken) internal view {
        bool isListed = InterfaceComptroller(comptrollerAddress).markets(seToken);
        if (!isListed) {
            revert SeTokenNotListed(seToken);
        }
    }

    /**
     * @notice Mint seBNB tokens to the market then transfer them to user
     * @param swapAmount Swapped BNB amount
     */
    function _mintVBNBandTransfer(uint256 swapAmount) internal {
        uint256 seBNBBalanceBefore = ISeBNB(seBNBAddress).balanceOf(address(this));
        ISeBNB(seBNBAddress).mint{ value: swapAmount }();
        uint256 seBNBBalanceAfter = ISeBNB(seBNBAddress).balanceOf(address(this));
        IERC20(seBNBAddress).safeTransfer(msg.sender, (seBNBBalanceAfter - seBNBBalanceBefore));
    }
}
