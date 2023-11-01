pragma solidity ^0.8.20;


import "../Tokens/SeTokens/SeBep20.sol";
import "../Tokens/SeTokens/SeToken.sol";
import "../Tokens/EIP20Interface.sol";
import "../../../oracle/contracts/PriceOracle.sol";
import "../Utils/ErrorReporter.sol";
import "../Comptroller/ComptrollerInterface.sol";
import "../Comptroller/ComptrollerLensInterface.sol";
import "../Tokens/SEUSD/SEUSDControllerInterface.sol";

/**
 * @title ComptrollerLens Contract
 * @author Segment
 * @notice The ComptrollerLens contract has functions to get the number of tokens that
 * can be seized through liquidation, hypothetical account liquidity and shortfall of an account.
 */
contract ComptrollerLens is ComptrollerLensInterface, ComptrollerErrorReporter, ExponentialNoError {
    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account liquidity.
     *  Note that `seTokenBalance` is the number of seTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint seTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    /**
     * @notice Computes the number of collateral tokens to be seized in a liquidation event
     * @param comptroller Address of comptroller
     * @param seTokenBorrowed Address of the borrowed seToken
     * @param seTokenCollateral Address of collateral for the borrow
     * @param actualRepayAmount Repayment amount i.e amount to be repaid of total borrowed amount
     * @return A tuple of error code, and tokens to seize
     */
    function liquidateCalculateSeizeTokens(
        address comptroller,
        address seTokenBorrowed,
        address seTokenCollateral,
        uint actualRepayAmount
    ) external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = ComptrollerInterface(comptroller).oracle().getUnderlyingPrice(
            SeToken(seTokenBorrowed)
        );
        uint priceCollateralMantissa = ComptrollerInterface(comptroller).oracle().getUnderlyingPrice(
            SeToken(seTokenCollateral)
        );
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = SeToken(seTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(
            Exp({ mantissa: ComptrollerInterface(comptroller).liquidationIncentiveMantissa() }),
            Exp({ mantissa: priceBorrowedMantissa })
        );
        denominator = mul_(Exp({ mantissa: priceCollateralMantissa }), Exp({ mantissa: exchangeRateMantissa }));
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /**
     * @notice Computes the number of SEUSD tokens to be seized in a liquidation event
     * @param comptroller Address of comptroller
     * @param seTokenCollateral Address of collateral for seToken
     * @param actualRepayAmount Repayment amount i.e amount to be repaid of the total borrowed amount
     * @return A tuple of error code, and tokens to seize
     */
    function liquidateSEUSDCalculateSeizeTokens(
        address comptroller,
        address seTokenCollateral,
        uint actualRepayAmount
    ) external view returns (uint, uint) {
        /* Read oracle prices for borrowed and collateral markets */
        uint priceBorrowedMantissa = 1e18; // Note: this is SEUSD
        uint priceCollateralMantissa = ComptrollerInterface(comptroller).oracle().getUnderlyingPrice(
            SeToken(seTokenCollateral)
        );
        if (priceCollateralMantissa == 0) {
            return (uint(Error.PRICE_ERROR), 0);
        }

        /*
         * Get the exchange rate and calculate the number of collateral tokens to seize:
         *  seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
         *  seizeTokens = seizeAmount / exchangeRate
         *   = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
         */
        uint exchangeRateMantissa = SeToken(seTokenCollateral).exchangeRateStored(); // Note: reverts on error
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;

        numerator = mul_(
            Exp({ mantissa: ComptrollerInterface(comptroller).liquidationIncentiveMantissa() }),
            Exp({ mantissa: priceBorrowedMantissa })
        );
        denominator = mul_(Exp({ mantissa: priceCollateralMantissa }), Exp({ mantissa: exchangeRateMantissa }));
        ratio = div_(numerator, denominator);

        seizeTokens = mul_ScalarTruncate(ratio, actualRepayAmount);

        return (uint(Error.NO_ERROR), seizeTokens);
    }

    /**
     * @notice Computes the hypothetical liquidity and shortfall of an account given a hypothetical borrow
     *      A snapshot of the account is taken and the total borrow amount of the account is calculated
     * @param comptroller Address of comptroller
     * @param account Address of the borrowed seToken
     * @param seTokenModify Address of collateral for seToken
     * @param redeemTokens Number of seTokens being redeemed
     * @param borrowAmount Amount borrowed
     * @return Returns a tuple of error code, liquidity, and shortfall
     */
    function getHypotheticalAccountLiquidity(
        address comptroller,
        address account,
        SeToken seTokenModify,
        uint redeemTokens,
        uint borrowAmount
    ) external view returns (uint, uint, uint) {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        // For each asset the account is in
        SeToken[] memory assets = ComptrollerInterface(comptroller).getAssetsIn(account);
        uint assetsCount = assets.length;
        for (uint i = 0; i < assetsCount; ++i) {
            SeToken asset = assets[i];

            // Read the balances and exchange rate from the seToken
            (oErr, vars.seTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(
                account
            );
            if (oErr != 0) {
                // semi-opaque error code, we assume NO_ERROR == 0 is invariant between upgrades
                return (uint(Error.SNAPSHOT_ERROR), 0, 0);
            }
            (, uint collateralFactorMantissa) = ComptrollerInterface(comptroller).markets(address(asset));
            vars.collateralFactor = Exp({ mantissa: collateralFactorMantissa });
            vars.exchangeRate = Exp({ mantissa: vars.exchangeRateMantissa });

            // Get the normalized price of the asset
            vars.oraclePriceMantissa = ComptrollerInterface(comptroller).oracle().getUnderlyingPrice(asset);
            if (vars.oraclePriceMantissa == 0) {
                return (uint(Error.PRICE_ERROR), 0, 0);
            }
            vars.oraclePrice = Exp({ mantissa: vars.oraclePriceMantissa });

            // Pre-compute a conversion factor from tokens -> bnb (normalized price value)
            vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

            // sumCollateral += tokensToDenom * seTokenBalance
            vars.sumCollateral = mul_ScalarTruncateAddUInt(vars.tokensToDenom, vars.seTokenBalance, vars.sumCollateral);

            // sumBorrowPlusEffects += oraclePrice * borrowBalance
            vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                vars.oraclePrice,
                vars.borrowBalance,
                vars.sumBorrowPlusEffects
            );

            // Calculate effects of interacting with seTokenModify
            if (asset == seTokenModify) {
                // redeem effect
                // sumBorrowPlusEffects += tokensToDenom * redeemTokens
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                    vars.tokensToDenom,
                    redeemTokens,
                    vars.sumBorrowPlusEffects
                );

                // borrow effect
                // sumBorrowPlusEffects += oraclePrice * borrowAmount
                vars.sumBorrowPlusEffects = mul_ScalarTruncateAddUInt(
                    vars.oraclePrice,
                    borrowAmount,
                    vars.sumBorrowPlusEffects
                );
            }
        }

        SEUSDControllerInterface seusdController = ComptrollerInterface(comptroller).seusdController();

        if (address(seusdController) != address(0)) {
            vars.sumBorrowPlusEffects = add_(vars.sumBorrowPlusEffects, seusdController.getSEUSDRepayAmount(account));
        }

        // These are safe, as the underflow condition is checked first
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (uint(Error.NO_ERROR), vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (uint(Error.NO_ERROR), 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }
}
