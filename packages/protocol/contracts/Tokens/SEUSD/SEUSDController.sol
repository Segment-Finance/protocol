pragma solidity ^0.8.20;

import "../../../../oracle/contracts/PriceOracle.sol";
import "../../Utils/ErrorReporter.sol";
import "../../Utils/Exponential.sol";
import "../../Comptroller/ComptrollerStorage.sol";
import "../../Comptroller/ComptrollerInterface.sol";
import "../../Governance/IAccessControlManager.sol";
import "../SeTokens/SeToken.sol";
import "./SEUSDControllerStorage.sol";
import "./SEUSDUnitroller.sol";
import "./SEUSD.sol";

/**
 * @title SEUSD Comptroller
 * @author Segment
 * @notice This is the implementation contract for the SEUSDUnitroller proxy
 */
contract SEUSDController is SEUSDControllerStorageG2, SEUSDControllerErrorReporter, Exponential {
    /// @notice Initial index used in interest computations
    uint public constant INITIAL_SEUSD_MINT_INDEX = 1e18;

    /// @notice Emitted when Comptroller is changed
    event NewComptroller(ComptrollerInterface oldComptroller, ComptrollerInterface newComptroller);

    /// @notice Event emitted when SEUSD is minted
    event MintSEUSD(address minter, uint mintSEUSDAmount);

    /// @notice Event emitted when SEUSD is repaid
    event RepaySEUSD(address payer, address borrower, uint repaySEUSDAmount);

    /// @notice Event emitted when a borrow is liquidated
    event LiquidateSEUSD(
        address liquidator,
        address borrower,
        uint repayAmount,
        address seTokenCollateral,
        uint seizeTokens
    );

    /// @notice Emitted when treasury guardian is changed
    event NewTreasuryGuardian(address oldTreasuryGuardian, address newTreasuryGuardian);

    /// @notice Emitted when treasury address is changed
    event NewTreasuryAddress(address oldTreasuryAddress, address newTreasuryAddress);

    /// @notice Emitted when treasury percent is changed
    event NewTreasuryPercent(uint oldTreasuryPercent, uint newTreasuryPercent);

    /// @notice Event emitted when SEUSDs are minted and fee are transferred
    event MintFee(address minter, uint feeAmount);

    /// @notice Emiitted when SEUSD base rate is changed
    event NewSEUSDBaseRate(uint256 oldBaseRateMantissa, uint256 newBaseRateMantissa);

    /// @notice Emiitted when SEUSD float rate is changed
    event NewSEUSDFloatRate(uint oldFloatRateMantissa, uint newFlatRateMantissa);

    /// @notice Emiitted when SEUSD receiver address is changed
    event NewSEUSDReceiver(address oldReceiver, address newReceiver);

    /// @notice Emiitted when SEUSD mint cap is changed
    event NewSEUSDMintCap(uint oldMintCap, uint newMintCap);

    /// @notice Emitted when access control address is changed by admin
    event NewAccessControl(address oldAccessControlAddress, address newAccessControlAddress);

    /*** Main Actions ***/
    struct MintLocalVars {
        uint oErr;
        MathError mathErr;
        uint mintAmount;
        uint accountMintSEUSDNew;
        uint accountMintableSEUSD;
    }

    function initialize() external onlyAdmin {
        require(seusdMintIndex == 0, "already initialized");

        seusdMintIndex = INITIAL_SEUSD_MINT_INDEX;
        accrualBlockNumber = getBlockNumber();
        mintCap = type(uint256).max;

        // The counter starts true to prevent changing it from zero to non-zero (i.e. smaller cost/refund)
        _notEntered = true;
    }

    function _become(SEUSDUnitroller unitroller) external {
        require(msg.sender == unitroller.admin(), "only unitroller admin can change brains");
        require(unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /**
     * @notice The mintSEUSD function mints and transfers SEUSD from the protocol to the user, and adds a borrow balance.
     * The amount minted must be less than the user's Account Liquidity and the mint seusd limit.
     * @param mintSEUSDAmount The amount of the SEUSD to be minted.
     * @return 0 on success, otherwise an error code
     */
    // solhint-disable-next-line code-complexity
    function mintSEUSD(uint mintSEUSDAmount) external nonReentrant returns (uint) {
        if (address(comptroller) != address(0)) {
            require(mintSEUSDAmount > 0, "mintSEUSDAmount cannot be zero");
            require(!comptroller.protocolPaused(), "protocol is paused");

            accrueSEUSDInterest();

            MintLocalVars memory vars;

            address minter = msg.sender;
            uint seusdTotalSupply = EIP20Interface(getSEUSDAddress()).totalSupply();
            uint seusdNewTotalSupply;

            (vars.mathErr, seusdNewTotalSupply) = addUInt(seusdTotalSupply, mintSEUSDAmount);
            require(seusdNewTotalSupply <= mintCap, "mint cap reached");

            if (vars.mathErr != MathError.NO_ERROR) {
                return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
            }

            (vars.oErr, vars.accountMintableSEUSD) = getMintableSEUSD(minter);
            if (vars.oErr != uint(Error.NO_ERROR)) {
                return uint(Error.REJECTION);
            }

            // check that user have sufficient mintableSEUSD balance
            if (mintSEUSDAmount > vars.accountMintableSEUSD) {
                return fail(Error.REJECTION, FailureInfo.SEUSD_MINT_REJECTION);
            }

            // Calculate the minted balance based on interest index
            uint totalMintedSEUSD = comptroller.mintedSEUSDs(minter);

            if (totalMintedSEUSD > 0) {
                uint256 repayAmount = getSEUSDRepayAmount(minter);
                uint remainedAmount;

                (vars.mathErr, remainedAmount) = subUInt(repayAmount, totalMintedSEUSD);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                (vars.mathErr, pastSEUSDInterest[minter]) = addUInt(pastSEUSDInterest[minter], remainedAmount);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                totalMintedSEUSD = repayAmount;
            }

            (vars.mathErr, vars.accountMintSEUSDNew) = addUInt(totalMintedSEUSD, mintSEUSDAmount);
            require(vars.mathErr == MathError.NO_ERROR, "SEUSD_MINT_AMOUNT_CALCULATION_FAILED");
            uint error = comptroller.setMintedSEUSDOf(minter, vars.accountMintSEUSDNew);
            if (error != 0) {
                return error;
            }

            uint feeAmount;
            uint remainedAmount;
            vars.mintAmount = mintSEUSDAmount;
            if (treasuryPercent != 0) {
                (vars.mathErr, feeAmount) = mulUInt(vars.mintAmount, treasuryPercent);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                (vars.mathErr, feeAmount) = divUInt(feeAmount, 1e18);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                (vars.mathErr, remainedAmount) = subUInt(vars.mintAmount, feeAmount);
                if (vars.mathErr != MathError.NO_ERROR) {
                    return failOpaque(Error.MATH_ERROR, FailureInfo.MINT_FEE_CALCULATION_FAILED, uint(vars.mathErr));
                }

                SEUSD(getSEUSDAddress()).mint(treasuryAddress, feeAmount);

                emit MintFee(minter, feeAmount);
            } else {
                remainedAmount = vars.mintAmount;
            }

            SEUSD(getSEUSDAddress()).mint(minter, remainedAmount);
            seusdMinterInterestIndex[minter] = seusdMintIndex;

            emit MintSEUSD(minter, remainedAmount);

            return uint(Error.NO_ERROR);
        }
    }

    /**
     * @notice The repay function transfers SEUSD into the protocol and burn, reducing the user's borrow balance.
     * Before repaying an asset, users must first approve the SEUSD to access their SEUSD balance.
     * @param repaySEUSDAmount The amount of the SEUSD to be repaid.
     * @return 0 on success, otherwise an error code
     */
    function repaySEUSD(uint repaySEUSDAmount) external nonReentrant returns (uint, uint) {
        if (address(comptroller) != address(0)) {
            accrueSEUSDInterest();

            require(repaySEUSDAmount > 0, "repaySEUSDAmount cannt be zero");

            require(!comptroller.protocolPaused(), "protocol is paused");

            return repaySEUSDFresh(msg.sender, msg.sender, repaySEUSDAmount);
        }
    }

    /**
     * @notice Repay SEUSD Internal
     * @notice Borrowed SEUSDs are repaid by another user (possibly the borrower).
     * @param payer the account paying off the SEUSD
     * @param borrower the account with the debt being payed off
     * @param repayAmount the amount of SEUSD being returned
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function repaySEUSDFresh(address payer, address borrower, uint repayAmount) internal returns (uint, uint) {
        MathError mErr;

        (uint burn, uint partOfCurrentInterest, uint partOfPastInterest) = getSEUSDCalculateRepayAmount(
            borrower,
            repayAmount
        );

        SEUSD(getSEUSDAddress()).burn(payer, burn);
        bool success = SEUSD(getSEUSDAddress()).transferFrom(payer, receiver, partOfCurrentInterest);
        require(success == true, "failed to transfer SEUSD fee");

        uint seusdBalanceBorrower = comptroller.mintedSEUSDs(borrower);
        uint accountSEUSDNew;

        (mErr, accountSEUSDNew) = subUInt(seusdBalanceBorrower, burn);
        require(mErr == MathError.NO_ERROR, "SEUSD_BURN_AMOUNT_CALCULATION_FAILED");

        (mErr, accountSEUSDNew) = subUInt(accountSEUSDNew, partOfPastInterest);
        require(mErr == MathError.NO_ERROR, "SEUSD_BURN_AMOUNT_CALCULATION_FAILED");

        (mErr, pastSEUSDInterest[borrower]) = subUInt(pastSEUSDInterest[borrower], partOfPastInterest);
        require(mErr == MathError.NO_ERROR, "SEUSD_BURN_AMOUNT_CALCULATION_FAILED");

        uint error = comptroller.setMintedSEUSDOf(borrower, accountSEUSDNew);
        if (error != 0) {
            return (error, 0);
        }
        emit RepaySEUSD(payer, borrower, burn);

        return (uint(Error.NO_ERROR), burn);
    }

    /**
     * @notice The sender liquidates the seusd minters collateral. The collateral seized is transferred to the liquidator.
     * @param borrower The borrower of seusd to be liquidated
     * @param seTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the underlying borrowed asset to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment amount.
     */
    function liquidateSEUSD(
        address borrower,
        uint repayAmount,
        SeTokenInterface seTokenCollateral
    ) external nonReentrant returns (uint, uint) {
        require(!comptroller.protocolPaused(), "protocol is paused");

        uint error = seTokenCollateral.accrueInterest();
        if (error != uint(Error.NO_ERROR)) {
            // accrueInterest emits logs on errors, but we still want to log the fact that an attempted liquidation failed
            return (fail(Error(error), FailureInfo.SEUSD_LIQUIDATE_ACCRUE_COLLATERAL_INTEREST_FAILED), 0);
        }

        // liquidateSEUSDFresh emits borrow-specific logs on errors, so we don't need to
        return liquidateSEUSDFresh(msg.sender, borrower, repayAmount, seTokenCollateral);
    }

    /**
     * @notice The liquidator liquidates the borrowers collateral by repay borrowers SEUSD.
     *  The collateral seized is transferred to the liquidator.
     * @param liquidator The address repaying the SEUSD and seizing collateral
     * @param borrower The borrower of this SEUSD to be liquidated
     * @param seTokenCollateral The market in which to seize collateral from the borrower
     * @param repayAmount The amount of the SEUSD to repay
     * @return (uint, uint) An error code (0=success, otherwise a failure, see ErrorReporter.sol), and the actual repayment SEUSD.
     */
    function liquidateSEUSDFresh(
        address liquidator,
        address borrower,
        uint repayAmount,
        SeTokenInterface seTokenCollateral
    ) internal returns (uint, uint) {
        if (address(comptroller) != address(0)) {
            accrueSEUSDInterest();

            /* Fail if liquidate not allowed */
            uint allowed = comptroller.liquidateBorrowAllowed(
                address(this),
                address(seTokenCollateral),
                liquidator,
                borrower,
                repayAmount
            );
            if (allowed != 0) {
                return (failOpaque(Error.REJECTION, FailureInfo.SEUSD_LIQUIDATE_COMPTROLLER_REJECTION, allowed), 0);
            }

            /* Verify seTokenCollateral market's block number equals current block number */
            //if (seTokenCollateral.accrualBlockNumber() != accrualBlockNumber) {
            if (seTokenCollateral.accrualBlockNumber() != getBlockNumber()) {
                return (fail(Error.REJECTION, FailureInfo.SEUSD_LIQUIDATE_COLLATERAL_FRESHNESS_CHECK), 0);
            }

            /* Fail if borrower = liquidator */
            if (borrower == liquidator) {
                return (fail(Error.REJECTION, FailureInfo.SEUSD_LIQUIDATE_LIQUIDATOR_IS_BORROWER), 0);
            }

            /* Fail if repayAmount = 0 */
            if (repayAmount == 0) {
                return (fail(Error.REJECTION, FailureInfo.SEUSD_LIQUIDATE_CLOSE_AMOUNT_IS_ZERO), 0);
            }

            /* Fail if repayAmount = -1 */
            if (repayAmount == type(uint256).max) {
                return (fail(Error.REJECTION, FailureInfo.SEUSD_LIQUIDATE_CLOSE_AMOUNT_IS_UINT_MAX), 0);
            }

            /* Fail if repaySEUSD fails */
            (uint repayBorrowError, uint actualRepayAmount) = repaySEUSDFresh(liquidator, borrower, repayAmount);
            if (repayBorrowError != uint(Error.NO_ERROR)) {
                return (fail(Error(repayBorrowError), FailureInfo.SEUSD_LIQUIDATE_REPAY_BORROW_FRESH_FAILED), 0);
            }

            /////////////////////////
            // EFFECTS & INTERACTIONS
            // (No safe failures beyond this point)

            /* We calculate the number of collateral tokens that will be seized */
            (uint amountSeizeError, uint seizeTokens) = comptroller.liquidateSEUSDCalculateSeizeTokens(
                address(seTokenCollateral),
                actualRepayAmount
            );
            require(
                amountSeizeError == uint(Error.NO_ERROR),
                "SEUSD_LIQUIDATE_COMPTROLLER_CALCULATE_AMOUNT_SEIZE_FAILED"
            );

            /* Revert if borrower collateral token balance < seizeTokens */
            require(seTokenCollateral.balanceOf(borrower) >= seizeTokens, "SEUSD_LIQUIDATE_SEIZE_TOO_MUCH");

            uint seizeError;
            seizeError = seTokenCollateral.seize(liquidator, borrower, seizeTokens);

            /* Revert if seize tokens fails (since we cannot be sure of side effects) */
            require(seizeError == uint(Error.NO_ERROR), "token seizure failed");

            /* We emit a LiquidateBorrow event */
            emit LiquidateSEUSD(liquidator, borrower, actualRepayAmount, address(seTokenCollateral), seizeTokens);

            /* We call the defense hook */
            comptroller.liquidateBorrowVerify(
                address(this),
                address(seTokenCollateral),
                liquidator,
                borrower,
                actualRepayAmount,
                seizeTokens
            );

            return (uint(Error.NO_ERROR), actualRepayAmount);
        }
    }

    /*** Admin Functions ***/

    /**
     * @notice Sets a new comptroller
     * @dev Admin function to set a new comptroller
     * @return uint 0=success, otherwise a failure (see ErrorReporter.sol for details)
     */
    function _setComptroller(ComptrollerInterface comptroller_) external returns (uint) {
        // Check caller is admin
        if (msg.sender != admin) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_COMPTROLLER_OWNER_CHECK);
        }

        ComptrollerInterface oldComptroller = comptroller;
        comptroller = comptroller_;
        emit NewComptroller(oldComptroller, comptroller_);

        return uint(Error.NO_ERROR);
    }

    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account total supply balance.
     *  Note that `seTokenBalance` is the number of seTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountAmountLocalVars {
        uint oErr;
        MathError mErr;
        uint sumSupply;
        uint marketSupply;
        uint sumBorrowPlusEffects;
        uint seTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    // solhint-disable-next-line code-complexity
    function getMintableSEUSD(address minter) public view returns (uint, uint) {
        PriceOracle oracle = comptroller.oracle();
        SeToken[] memory enteredMarkets = comptroller.getAssetsIn(minter);

        AccountAmountLocalVars memory vars; // Holds all our calculation results

        uint accountMintableSEUSD;
        uint i;

        /**
         * We use this formula to calculate mintable SEUSD amount.
         * totalSupplyAmount * SEUSDMintRate - (totalBorrowAmount + mintedSEUSDOf)
         */
        for (i = 0; i < enteredMarkets.length; i++) {
            (vars.oErr, vars.seTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = enteredMarkets[i]
                .getAccountSnapshot(minter);
            if (vars.oErr != 0) {
                // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (uint(Error.SNAPSHOT_ERROR), 0);
            }
            vars.exchangeRate = Exp({ mantissa: vars.exchangeRateMantissa });

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(enteredMarkets[i]);
            if (vars.oraclePriceMantissa == 0) {
                return (uint(Error.PRICE_ERROR), 0);
            }
            vars.oraclePrice = Exp({ mantissa: vars.oraclePriceMantissa });

            (vars.mErr, vars.tokensToDenom) = mulExp(vars.exchangeRate, vars.oraclePrice);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            // marketSupply = tokensToDenom * seTokenBalance
            (vars.mErr, vars.marketSupply) = mulScalarTruncate(vars.tokensToDenom, vars.seTokenBalance);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            (, uint collateralFactorMantissa) = comptroller.markets(address(enteredMarkets[i]));
            (vars.mErr, vars.marketSupply) = mulUInt(vars.marketSupply, collateralFactorMantissa);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            (vars.mErr, vars.marketSupply) = divUInt(vars.marketSupply, 1e18);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            (vars.mErr, vars.sumSupply) = addUInt(vars.sumSupply, vars.marketSupply);
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            (vars.mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(
                vars.oraclePrice,
                vars.borrowBalance,
                vars.sumBorrowPlusEffects
            );
            if (vars.mErr != MathError.NO_ERROR) {
                return (uint(Error.MATH_ERROR), 0);
            }
        }

        uint totalMintedSEUSD = comptroller.mintedSEUSDs(minter);
        uint256 repayAmount = 0;

        if (totalMintedSEUSD > 0) {
            repayAmount = getSEUSDRepayAmount(minter);
        }

        (vars.mErr, vars.sumBorrowPlusEffects) = addUInt(vars.sumBorrowPlusEffects, repayAmount);
        if (vars.mErr != MathError.NO_ERROR) {
            return (uint(Error.MATH_ERROR), 0);
        }

        (vars.mErr, accountMintableSEUSD) = mulUInt(vars.sumSupply, comptroller.seusdMintRate());
        require(vars.mErr == MathError.NO_ERROR, "SEUSD_MINT_AMOUNT_CALCULATION_FAILED");

        (vars.mErr, accountMintableSEUSD) = divUInt(accountMintableSEUSD, 10000);
        require(vars.mErr == MathError.NO_ERROR, "SEUSD_MINT_AMOUNT_CALCULATION_FAILED");

        (vars.mErr, accountMintableSEUSD) = subUInt(accountMintableSEUSD, vars.sumBorrowPlusEffects);
        if (vars.mErr != MathError.NO_ERROR) {
            return (uint(Error.REJECTION), 0);
        }

        return (uint(Error.NO_ERROR), accountMintableSEUSD);
    }

    function _setTreasuryData(
        address newTreasuryGuardian,
        address newTreasuryAddress,
        uint newTreasuryPercent
    ) external returns (uint) {
        // Check caller is admin
        if (!(msg.sender == admin || msg.sender == treasuryGuardian)) {
            return fail(Error.UNAUTHORIZED, FailureInfo.SET_TREASURY_OWNER_CHECK);
        }

        require(newTreasuryPercent < 1e18, "treasury percent cap overflow");

        address oldTreasuryGuardian = treasuryGuardian;
        address oldTreasuryAddress = treasuryAddress;
        uint oldTreasuryPercent = treasuryPercent;

        treasuryGuardian = newTreasuryGuardian;
        treasuryAddress = newTreasuryAddress;
        treasuryPercent = newTreasuryPercent;

        emit NewTreasuryGuardian(oldTreasuryGuardian, newTreasuryGuardian);
        emit NewTreasuryAddress(oldTreasuryAddress, newTreasuryAddress);
        emit NewTreasuryPercent(oldTreasuryPercent, newTreasuryPercent);

        return uint(Error.NO_ERROR);
    }

    function getSEUSDRepayRate() public view returns (uint) {
        PriceOracle oracle = comptroller.oracle();
        MathError mErr;

        if (baseRateMantissa > 0) {
            if (floatRateMantissa > 0) {
                uint oraclePrice = oracle.getUnderlyingPrice(SeToken(getSEUSDAddress()));
                if (1e18 > oraclePrice) {
                    uint delta;
                    uint rate;

                    (mErr, delta) = subUInt(1e18, oraclePrice);
                    require(mErr == MathError.NO_ERROR, "SEUSD_REPAY_RATE_CALCULATION_FAILED");

                    (mErr, delta) = mulUInt(delta, floatRateMantissa);
                    require(mErr == MathError.NO_ERROR, "SEUSD_REPAY_RATE_CALCULATION_FAILED");

                    (mErr, delta) = divUInt(delta, 1e18);
                    require(mErr == MathError.NO_ERROR, "SEUSD_REPAY_RATE_CALCULATION_FAILED");

                    (mErr, rate) = addUInt(delta, baseRateMantissa);
                    require(mErr == MathError.NO_ERROR, "SEUSD_REPAY_RATE_CALCULATION_FAILED");

                    return rate;
                } else {
                    return baseRateMantissa;
                }
            } else {
                return baseRateMantissa;
            }
        } else {
            return 0;
        }
    }

    function getSEUSDRepayRatePerBlock() public view returns (uint) {
        uint yearlyRate = getSEUSDRepayRate();

        MathError mErr;
        uint rate;

        (mErr, rate) = divUInt(yearlyRate, getBlocksPerYear());
        require(mErr == MathError.NO_ERROR, "SEUSD_REPAY_RATE_CALCULATION_FAILED");

        return rate;
    }

    function getSEUSDMinterInterestIndex(address minter) public view returns (uint) {
        uint storedIndex = seusdMinterInterestIndex[minter];
        // If the user minted SEUSD before the stability fee was introduced, accrue
        // starting from stability fee launch
        if (storedIndex == 0) {
            return INITIAL_SEUSD_MINT_INDEX;
        }
        return storedIndex;
    }

    /**
     * @notice Get the current total SEUSD a user needs to repay
     * @param account The address of the SEUSD borrower
     * @return (uint) The total amount of SEUSD the user needs to repay
     */
    function getSEUSDRepayAmount(address account) public view returns (uint) {
        MathError mErr;
        uint delta;

        uint amount = comptroller.mintedSEUSDs(account);
        uint interest = pastSEUSDInterest[account];
        uint totalMintedSEUSD;
        uint newInterest;

        (mErr, totalMintedSEUSD) = subUInt(amount, interest);
        require(mErr == MathError.NO_ERROR, "SEUSD_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        (mErr, delta) = subUInt(seusdMintIndex, getSEUSDMinterInterestIndex(account));
        require(mErr == MathError.NO_ERROR, "SEUSD_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        (mErr, newInterest) = mulUInt(delta, totalMintedSEUSD);
        require(mErr == MathError.NO_ERROR, "SEUSD_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        (mErr, newInterest) = divUInt(newInterest, 1e18);
        require(mErr == MathError.NO_ERROR, "SEUSD_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        (mErr, amount) = addUInt(amount, newInterest);
        require(mErr == MathError.NO_ERROR, "SEUSD_TOTAL_REPAY_AMOUNT_CALCULATION_FAILED");

        return amount;
    }

    /**
     * @notice Calculate how much SEUSD the user needs to repay
     * @param borrower The address of the SEUSD borrower
     * @param repayAmount The amount of SEUSD being returned
     * @return (uint, uint, uint) Amount of SEUSD to be burned, amount of SEUSD the user needs to pay in current interest and amount of SEUSD the user needs to pay in past interest
     */
    function getSEUSDCalculateRepayAmount(address borrower, uint256 repayAmount) public view returns (uint, uint, uint) {
        MathError mErr;
        uint256 totalRepayAmount = getSEUSDRepayAmount(borrower);
        uint currentInterest;

        (mErr, currentInterest) = subUInt(totalRepayAmount, comptroller.mintedSEUSDs(borrower));
        require(mErr == MathError.NO_ERROR, "SEUSD_BURN_AMOUNT_CALCULATION_FAILED");

        (mErr, currentInterest) = addUInt(pastSEUSDInterest[borrower], currentInterest);
        require(mErr == MathError.NO_ERROR, "SEUSD_BURN_AMOUNT_CALCULATION_FAILED");

        uint burn;
        uint partOfCurrentInterest = currentInterest;
        uint partOfPastInterest = pastSEUSDInterest[borrower];

        if (repayAmount >= totalRepayAmount) {
            (mErr, burn) = subUInt(totalRepayAmount, currentInterest);
            require(mErr == MathError.NO_ERROR, "SEUSD_BURN_AMOUNT_CALCULATION_FAILED");
        } else {
            uint delta;

            (mErr, delta) = mulUInt(repayAmount, 1e18);
            require(mErr == MathError.NO_ERROR, "SEUSD_PART_CALCULATION_FAILED");

            (mErr, delta) = divUInt(delta, totalRepayAmount);
            require(mErr == MathError.NO_ERROR, "SEUSD_PART_CALCULATION_FAILED");

            uint totalMintedAmount;
            (mErr, totalMintedAmount) = subUInt(totalRepayAmount, currentInterest);
            require(mErr == MathError.NO_ERROR, "SEUSD_MINTED_AMOUNT_CALCULATION_FAILED");

            (mErr, burn) = mulUInt(totalMintedAmount, delta);
            require(mErr == MathError.NO_ERROR, "SEUSD_BURN_AMOUNT_CALCULATION_FAILED");

            (mErr, burn) = divUInt(burn, 1e18);
            require(mErr == MathError.NO_ERROR, "SEUSD_BURN_AMOUNT_CALCULATION_FAILED");

            (mErr, partOfCurrentInterest) = mulUInt(currentInterest, delta);
            require(mErr == MathError.NO_ERROR, "SEUSD_CURRENT_INTEREST_AMOUNT_CALCULATION_FAILED");

            (mErr, partOfCurrentInterest) = divUInt(partOfCurrentInterest, 1e18);
            require(mErr == MathError.NO_ERROR, "SEUSD_CURRENT_INTEREST_AMOUNT_CALCULATION_FAILED");

            (mErr, partOfPastInterest) = mulUInt(pastSEUSDInterest[borrower], delta);
            require(mErr == MathError.NO_ERROR, "SEUSD_PAST_INTEREST_CALCULATION_FAILED");

            (mErr, partOfPastInterest) = divUInt(partOfPastInterest, 1e18);
            require(mErr == MathError.NO_ERROR, "SEUSD_PAST_INTEREST_CALCULATION_FAILED");
        }

        return (burn, partOfCurrentInterest, partOfPastInterest);
    }

    function accrueSEUSDInterest() public {
        MathError mErr;
        uint delta;

        (mErr, delta) = mulUInt(getSEUSDRepayRatePerBlock(), getBlockNumber() - accrualBlockNumber);
        require(mErr == MathError.NO_ERROR, "SEUSD_INTEREST_ACCURE_FAILED");

        (mErr, delta) = addUInt(delta, seusdMintIndex);
        require(mErr == MathError.NO_ERROR, "SEUSD_INTEREST_ACCURE_FAILED");

        seusdMintIndex = delta;
        accrualBlockNumber = getBlockNumber();
    }

    /**
     * @notice Sets the address of the access control of this contract
     * @dev Admin function to set the access control address
     * @param newAccessControlAddress New address for the access control
     */
    function setAccessControl(address newAccessControlAddress) external onlyAdmin {
        _ensureNonzeroAddress(newAccessControlAddress);

        address oldAccessControlAddress = accessControl;
        accessControl = newAccessControlAddress;
        emit NewAccessControl(oldAccessControlAddress, accessControl);
    }

    /**
     * @notice Set SEUSD borrow base rate
     * @param newBaseRateMantissa the base rate multiplied by 10**18
     */
    function setBaseRate(uint newBaseRateMantissa) external {
        _ensureAllowed("setBaseRate(uint256)");

        uint old = baseRateMantissa;
        baseRateMantissa = newBaseRateMantissa;
        emit NewSEUSDBaseRate(old, baseRateMantissa);
    }

    /**
     * @notice Set SEUSD borrow float rate
     * @param newFloatRateMantissa the SEUSD float rate multiplied by 10**18
     */
    function setFloatRate(uint newFloatRateMantissa) external {
        _ensureAllowed("setFloatRate(uint256)");

        uint old = floatRateMantissa;
        floatRateMantissa = newFloatRateMantissa;
        emit NewSEUSDFloatRate(old, floatRateMantissa);
    }

    /**
     * @notice Set SEUSD stability fee receiver address
     * @param newReceiver the address of the SEUSD fee receiver
     */
    function setReceiver(address newReceiver) external onlyAdmin {
        require(newReceiver != address(0), "invalid receiver address");

        address old = receiver;
        receiver = newReceiver;
        emit NewSEUSDReceiver(old, newReceiver);
    }

    /**
     * @notice Set SEUSD mint cap
     * @param _mintCap the amount of SEUSD that can be minted
     */
    function setMintCap(uint _mintCap) external {
        _ensureAllowed("setMintCap(uint256)");

        uint old = mintCap;
        mintCap = _mintCap;
        emit NewSEUSDMintCap(old, _mintCap);
    }

    function getBlockNumber() internal view returns (uint) {
        return block.number;
    }

    function getBlocksPerYear() public view returns (uint) {
        return 10512000; //(24 * 60 * 60 * 365) / 3;
    }

    /**
     * @notice Return the address of the SEUSD token
     * @return The address of SEUSD
     */
    function getSEUSDAddress() public view returns (address) {
        return 0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    /*** Reentrancy Guard ***/

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }

    function _ensureAllowed(string memory functionSig) private view {
        require(IAccessControlManager(accessControl).isAllowedToCall(msg.sender, functionSig), "access denied");
    }

    /// @notice Reverts if the passed address is zero
    function _ensureNonzeroAddress(address someone) private pure {
        require(someone != address(0), "can't be zero address");
    }
}
