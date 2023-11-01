// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "../../../governance-contracts/contracts/Governance/AccessControlledV8.sol";
import { ResilientOracleInterface } from "../../../oracle/contracts/interfaces/OracleInterface.sol";
import { ISEUSD } from "./ISEUSD.sol";

/**
 * @title Peg Stability Contract.
 * @notice Contract for swapping stable token for SEUSD token and vice versa to maintain the peg stability between them.
 * @author Segment Protocol
 */
contract PegStability is AccessControlledV8, ReentrancyGuardUpgradeable {
    using SafeERC20 for IERC20;

    // Helper enum for calculation of the fee.
    enum FeeDirection {
        IN,
        OUT
    }

    /// @notice The divisor used to convert fees to basis points.
    uint256 public constant BASIS_POINTS_DIVISOR = 10000;

    /// @notice The mantissa value representing 1 (used for calculations).
    uint256 public constant MANTISSA_ONE = 1e18;

    /// @notice The value representing one dollar in the stable token.
    /// @dev Our oracle is returning amount depending on the number of decimals of the stable token. (36 - asset_decimals) E.g. 8 decimal asset = 1e28.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    uint256 public immutable ONE_DOLLAR;

    /// @notice SEUSD token contract.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    ISEUSD public immutable SEUSD;

    /// @notice The address of the stable token contract.
    /// @custom:oz-upgrades-unsafe-allow state-variable-immutable
    address public immutable STABLE_TOKEN_ADDRESS;

    /// @notice The address of ResilientOracle contract wrapped in its interface.
    ResilientOracleInterface public oracle;

    /// @notice The address of the Segment Treasury contract.
    address public segmentTreasury;

    /// @notice The incoming stableCoin fee. (Fee for swapStableForSEUSD).
    uint256 public feeIn;

    /// @notice The outgoing stableCoin fee. (Fee for swapSEUSDForStable).
    uint256 public feeOut;

    /// @notice The maximum amount of SEUSD that can be minted through this contract.
    uint256 public seusdMintCap;

    /// @notice The total amount of SEUSD minted through this contract.
    uint256 public seusdMinted;

    /// @notice A flag indicating whether the contract is currently paused or not.
    bool public isPaused;

    /// @notice Event emitted when contract is paused.
    event PSMPaused(address indexed admin);

    /// @notice Event emitted when the contract is resumed after pause.
    event PSMResumed(address indexed admin);

    /// @notice Event emitted when feeIn state var is modified.
    event FeeInChanged(uint256 oldFeeIn, uint256 newFeeIn);

    /// @notice Event emitted when feeOut state var is modified.
    event FeeOutChanged(uint256 oldFeeOut, uint256 newFeeOut);

    /// @notice Event emitted when seusdMintCap state var is modified.
    event SEUSDMintCapChanged(uint256 oldCap, uint256 newCap);

    /// @notice Event emitted when segmentTreasury state var is modified.
    event SegmentTreasuryChanged(address indexed oldTreasury, address indexed newTreasury);

    /// @notice Event emitted when oracle state var is modified.
    event OracleChanged(address indexed oldOracle, address indexed newOracle);

    /// @notice Event emitted when stable token is swapped for SEUSD.
    event StableForSEUSDSwapped(uint256 stableIn, uint256 seusdOut, uint256 fee);

    /// @notice Event emitted when stable token is swapped for SEUSD.
    event SEUSDForStableSwapped(uint256 seusdBurnt, uint256 stableOut, uint256 seusdFee);

    /// @notice thrown when contract is in paused state
    error Paused();

    /// @notice thrown when attempted to pause an already paused contract
    error AlreadyPaused();

    /// @notice thrown when attempted to resume the contract if it is already resumed
    error NotPaused();

    /// @notice thrown when stable token has more than 18 decimals
    error TooManyDecimals();

    /// @notice thrown when fee is >= 100%
    error InvalidFee();

    /// @notice thrown when a zero address is passed as a function parameter
    error ZeroAddress();

    /// @notice thrown when a zero amount is passed as stable token amount parameter
    error ZeroAmount();

    /// @notice thrown when the user doesn't have enough SEUSD balance to provide for the amount of stable tokens he wishes to get
    error NotEnoughSEUSD();

    /// @notice thrown when the amount of SEUSD to be burnt exceeds the seusdMinted amount
    error SEUSDMintedUnderflow();

    /// @notice thrown when the SEUSD transfer to treasury fails
    error SEUSDTransferFail();

    /// @notice thrown when SEUSD to be minted will go beyond the mintCap threshold
    error SEUSDMintCapReached();
    /// @notice thrown when fee calculation will result in rounding down to 0 due to stable token amount being a too small number
    error AmountTooSmall();

    /**
     * @dev Prevents functions to execute when contract is paused.
     */
    modifier isActive() {
        if (isPaused) revert Paused();
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address stableTokenAddress_, address seusdAddress_) {
        _ensureNonzeroAddress(stableTokenAddress_);
        _ensureNonzeroAddress(seusdAddress_);

        uint256 decimals_ = IERC20Metadata(stableTokenAddress_).decimals();

        if (decimals_ > 18) {
            revert TooManyDecimals();
        }

        ONE_DOLLAR = 10 ** (36 - decimals_); // 1$ scaled to the decimals returned by our Oracle
        STABLE_TOKEN_ADDRESS = stableTokenAddress_;
        SEUSD = ISEUSD(seusdAddress_);
        _disableInitializers();
    }

    /**
     * @notice Initializes the contract via Proxy Contract with the required parameters.
     * @param accessControlManager_ The address of the AccessControlManager contract.
     * @param segmentTreasury_ The address where fees will be sent.
     * @param oracleAddress_ The address of the ResilientOracle contract.
     * @param feeIn_ The percentage of fees to be applied to a stablecoin -> SEUSD swap.
     * @param feeOut_ The percentage of fees to be applied to a SEUSD -> stablecoin swap.
     * @param seusdMintCap_ The cap for the total amount of SEUSD that can be minted.
     */
    function initialize(
        address accessControlManager_,
        address segmentTreasury_,
        address oracleAddress_,
        uint256 feeIn_,
        uint256 feeOut_,
        uint256 seusdMintCap_
    ) external initializer {
        _ensureNonzeroAddress(accessControlManager_);
        _ensureNonzeroAddress(segmentTreasury_);
        _ensureNonzeroAddress(oracleAddress_);
        __AccessControlled_init(accessControlManager_);
        __ReentrancyGuard_init();

        if (feeIn_ >= BASIS_POINTS_DIVISOR || feeOut_ >= BASIS_POINTS_DIVISOR) {
            revert InvalidFee();
        }

        feeIn = feeIn_;
        feeOut = feeOut_;
        seusdMintCap = seusdMintCap_;
        segmentTreasury = segmentTreasury_;
        oracle = ResilientOracleInterface(oracleAddress_);
    }

    /*** Swap Functions ***/

    /**
     * @notice Swaps SEUSD for a stable token.
     * @param receiver The address where the stablecoin will be sent.
     * @param stableTknAmount The amount of stable tokens to receive.
     * @return The amount of SEUSD received and burnt from the sender.
     */
    // @custom:event Emits SEUSDForStableSwapped event.
    function swapSEUSDForStable(
        address receiver,
        uint256 stableTknAmount
    ) external isActive nonReentrant returns (uint256) {
        _ensureNonzeroAddress(receiver);
        _ensureNonzeroAmount(stableTknAmount);

        // update oracle price and calculate USD value of the stable token amount scaled in 18 decimals
        oracle.updateAssetPrice(STABLE_TOKEN_ADDRESS);
        uint256 stableTknAmountUSD = _previewTokenUSDAmount(stableTknAmount, FeeDirection.OUT);
        uint256 fee = _calculateFee(stableTknAmountUSD, FeeDirection.OUT);

        if (SEUSD.balanceOf(msg.sender) < stableTknAmountUSD + fee) {
            revert NotEnoughSEUSD();
        }
        if (seusdMinted < stableTknAmountUSD) {
            revert SEUSDMintedUnderflow();
        }

        unchecked {
            seusdMinted -= stableTknAmountUSD;
        }

        if (fee != 0) {
            bool success = SEUSD.transferFrom(msg.sender, segmentTreasury, fee);
            if (!success) {
                revert SEUSDTransferFail();
            }
        }

        SEUSD.burn(msg.sender, stableTknAmountUSD);
        IERC20(STABLE_TOKEN_ADDRESS).safeTransfer(receiver, stableTknAmount);
        emit SEUSDForStableSwapped(stableTknAmountUSD, stableTknAmount, fee);
        return stableTknAmountUSD;
    }

    /**
     * @notice Swaps stable tokens for SEUSD with fees.
     * @dev This function adds support to fee-on-transfer tokens. The actualTransferAmt is calculated, by recording token balance state before and after the transfer.
     * @param receiver The address that will receive the SEUSD tokens.
     * @param stableTknAmount The amount of stable tokens to be swapped.
     * @return Amount of SEUSD minted to the sender.
     */
    // @custom:event Emits StableForSEUSDSwapped event.
    function swapStableForSEUSD(
        address receiver,
        uint256 stableTknAmount
    ) external isActive nonReentrant returns (uint256) {
        _ensureNonzeroAddress(receiver);
        _ensureNonzeroAmount(stableTknAmount);
        // transfer IN, supporting fee-on-transfer tokens
        uint256 balanceBefore = IERC20(STABLE_TOKEN_ADDRESS).balanceOf(address(this));
        IERC20(STABLE_TOKEN_ADDRESS).safeTransferFrom(msg.sender, address(this), stableTknAmount);
        uint256 balanceAfter = IERC20(STABLE_TOKEN_ADDRESS).balanceOf(address(this));

        //calculate actual transfered amount (in case of fee-on-transfer tokens)
        uint256 actualTransferAmt = balanceAfter - balanceBefore;

        // update oracle price and calculate USD value of the stable token amount scaled in 18 decimals
        oracle.updateAssetPrice(STABLE_TOKEN_ADDRESS);
        uint256 actualTransferAmtInUSD = _previewTokenUSDAmount(actualTransferAmt, FeeDirection.IN);

        //calculate feeIn
        uint256 fee = _calculateFee(actualTransferAmtInUSD, FeeDirection.IN);
        uint256 seusdToMint = actualTransferAmtInUSD - fee;

        if (seusdMinted + actualTransferAmtInUSD > seusdMintCap) {
            revert SEUSDMintCapReached();
        }
        unchecked {
            seusdMinted += actualTransferAmtInUSD;
        }

        // mint SEUSD to receiver
        SEUSD.mint(receiver, seusdToMint);

        // mint SEUSD fee to segment treasury
        if (fee != 0) {
            SEUSD.mint(segmentTreasury, fee);
        }

        emit StableForSEUSDSwapped(actualTransferAmt, seusdToMint, fee);
        return seusdToMint;
    }

    /*** Admin Functions ***/

    /**
     * @notice Pause the PSM contract.
     * @dev Reverts if the contract is already paused.
     */
    // @custom:event Emits PSMPaused event.
    function pause() external {
        _checkAccessAllowed("pause()");
        if (isPaused) {
            revert AlreadyPaused();
        }
        isPaused = true;
        emit PSMPaused(msg.sender);
    }

    /**
     * @notice Resume the PSM contract.
     * @dev Reverts if the contract is not paused.
     */
    // @custom:event Emits PSMResumed event.
    function resume() external {
        _checkAccessAllowed("resume()");
        if (!isPaused) {
            revert NotPaused();
        }
        isPaused = false;
        emit PSMResumed(msg.sender);
    }

    /**
     * @notice Set the fee percentage for incoming swaps.
     * @dev Reverts if the new fee percentage is invalid (greater than or equal to BASIS_POINTS_DIVISOR).
     * @param feeIn_ The new fee percentage for incoming swaps.
     */
    // @custom:event Emits FeeInChanged event.
    function setFeeIn(uint256 feeIn_) external {
        _checkAccessAllowed("setFeeIn(uint256)");
        // feeIn = 10000 = 100%
        if (feeIn_ >= BASIS_POINTS_DIVISOR) {
            revert InvalidFee();
        }
        uint256 oldFeeIn = feeIn;
        feeIn = feeIn_;
        emit FeeInChanged(oldFeeIn, feeIn_);
    }

    /**
     * @notice Set the fee percentage for outgoing swaps.
     * @dev Reverts if the new fee percentage is invalid (greater than or equal to BASIS_POINTS_DIVISOR).
     * @param feeOut_ The new fee percentage for outgoing swaps.
     */
    // @custom:event Emits FeeOutChanged event.
    function setFeeOut(uint256 feeOut_) external {
        _checkAccessAllowed("setFeeOut(uint256)");
        // feeOut = 10000 = 100%
        if (feeOut_ >= BASIS_POINTS_DIVISOR) {
            revert InvalidFee();
        }
        uint256 oldFeeOut = feeOut;
        feeOut = feeOut_;
        emit FeeOutChanged(oldFeeOut, feeOut_);
    }

    /**
     * @dev Set the maximum amount of SEUSD that can be minted through this contract.
     * @param seusdMintCap_ The new maximum amount of SEUSD that can be minted.
     */
    // @custom:event Emits SEUSDMintCapChanged event.
    function setSEUSDMintCap(uint256 seusdMintCap_) external {
        _checkAccessAllowed("setSEUSDMintCap(uint256)");
        uint256 oldSEUSDMintCap = seusdMintCap;
        seusdMintCap = seusdMintCap_;
        emit SEUSDMintCapChanged(oldSEUSDMintCap, seusdMintCap_);
    }

    /**
     * @notice Set the address of the Segment Treasury contract.
     * @dev Reverts if the new address is zero.
     * @param segmentTreasury_ The new address of the Segment Treasury contract.
     */
    // @custom:event Emits SegmentTreasuryChanged event.
    function setSegmentTreasury(address segmentTreasury_) external {
        _checkAccessAllowed("setSegmentTreasury(address)");
        _ensureNonzeroAddress(segmentTreasury_);
        address oldTreasuryAddress = segmentTreasury;
        segmentTreasury = segmentTreasury_;
        emit SegmentTreasuryChanged(oldTreasuryAddress, segmentTreasury_);
    }

    /**
     * @notice Set the address of the ResilientOracle contract.
     * @dev Reverts if the new address is zero.
     * @param oracleAddress_ The new address of the ResilientOracle contract.
     */
    // @custom:event Emits OracleChanged event.
    function setOracle(address oracleAddress_) external {
        _checkAccessAllowed("setOracle(address)");
        _ensureNonzeroAddress(oracleAddress_);
        address oldOracleAddress = address(oracle);
        oracle = ResilientOracleInterface(oracleAddress_);
        emit OracleChanged(oldOracleAddress, oracleAddress_);
    }

    /**
     * @dev Disabling renounceOwnership function.
     */
    function renounceOwnership() public override {}

    /*** Helper Functions ***/

    /**
     * @notice Calculates the amount of SEUSD that would be burnt from the user.
     * @dev This calculation might be off with a bit, if the price of the oracle for this asset is not updated in the block this function is invoked.
     * @param stableTknAmount The amount of stable tokens to be received after the swap.
     * @return The amount of SEUSD that would be taken from the user.
     */
    function previewSwapSEUSDForStable(uint256 stableTknAmount) external view returns (uint256) {
        _ensureNonzeroAmount(stableTknAmount);
        uint256 stableTknAmountUSD = _previewTokenUSDAmount(stableTknAmount, FeeDirection.OUT);
        uint256 fee = _calculateFee(stableTknAmountUSD, FeeDirection.OUT);

        if (seusdMinted < stableTknAmountUSD) {
            revert SEUSDMintedUnderflow();
        }

        return stableTknAmountUSD + fee;
    }

    /**
     * @notice Calculates the amount of SEUSD that would be sent to the receiver.
     * @dev This calculation might be off with a bit, if the price of the oracle for this asset is not updated in the block this function is invoked.
     * @param stableTknAmount The amount of stable tokens provided for the swap.
     * @return The amount of SEUSD that would be sent to the receiver.
     */
    function previewSwapStableForSEUSD(uint256 stableTknAmount) external view returns (uint256) {
        _ensureNonzeroAmount(stableTknAmount);
        uint256 stableTknAmountUSD = _previewTokenUSDAmount(stableTknAmount, FeeDirection.IN);

        //calculate feeIn
        uint256 fee = _calculateFee(stableTknAmountUSD, FeeDirection.IN);
        uint256 seusdToMint = stableTknAmountUSD - fee;

        if (seusdMinted + stableTknAmountUSD > seusdMintCap) {
            revert SEUSDMintCapReached();
        }

        return seusdToMint;
    }

    /**
     * @dev Calculates the USD value of the given amount of stable tokens depending on the swap direction.
     * @param amount The amount of stable tokens.
     * @param direction The direction of the swap.
     * @return The USD value of the given amount of stable tokens scaled by 1e18 taking into account the direction of the swap
     */
    function _previewTokenUSDAmount(uint256 amount, FeeDirection direction) internal view returns (uint256) {
        return (amount * _getPriceInUSD(direction)) / MANTISSA_ONE;
    }

    /**
     * @notice Get the price of stable token in USD.
     * @dev This function returns either min(1$,oraclePrice) or max(1$,oraclePrice) with a decimal scale (36 - asset_decimals). E.g. for 8 decimal token 1$ will be 1e28.
     * @param direction The direction of the swap: FeeDirection.IN or FeeDirection.OUT.
     * @return The price in USD, adjusted based on the selected direction.
     */
    function _getPriceInUSD(FeeDirection direction) internal view returns (uint256) {
        // get price with a scale = (36 - asset_decimals)
        uint256 price = oracle.getPrice(STABLE_TOKEN_ADDRESS);

        if (direction == FeeDirection.IN) {
            // MIN(1, price)
            return price < ONE_DOLLAR ? price : ONE_DOLLAR;
        } else {
            // MAX(1, price)
            return price > ONE_DOLLAR ? price : ONE_DOLLAR;
        }
    }

    /**
     * @notice Calculate the fee amount based on the input amount and fee percentage.
     * @dev Reverts if the fee percentage calculation results in rounding down to 0.
     * @param amount The input amount to calculate the fee from.
     * @param direction The direction of the fee: FeeDirection.IN or FeeDirection.OUT.
     * @return The fee amount.
     */
    function _calculateFee(uint256 amount, FeeDirection direction) internal view returns (uint256) {
        uint256 feePercent;
        if (direction == FeeDirection.IN) {
            feePercent = feeIn;
        } else {
            feePercent = feeOut;
        }
        if (feePercent == 0) {
            return 0;
        } else {
            // checking if the percent calculation will result in rounding down to 0
            if (amount * feePercent < BASIS_POINTS_DIVISOR) {
                revert AmountTooSmall();
            }
            return (amount * feePercent) / BASIS_POINTS_DIVISOR;
        }
    }

    /**
     * @notice Checks that the address is not the zero address.
     * @param someone The address to check.
     */
    function _ensureNonzeroAddress(address someone) private pure {
        if (someone == address(0)) revert ZeroAddress();
    }

    /**
     * @notice Checks that the amount passed as stable tokens is bigger than zero
     * @param amount The amount to validate
     */
    function _ensureNonzeroAmount(uint256 amount) private pure {
        if (amount == 0) revert ZeroAmount();
    }
}
