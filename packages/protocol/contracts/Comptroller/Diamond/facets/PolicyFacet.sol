// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { IPolicyFacet } from "../interfaces/IPolicyFacet.sol";

import { SEFRewardsHelper, SeToken } from "./SEFRewardsHelper.sol";

/**
 * @title PolicyFacet
 * @author Segment
 * @dev This facet contains all the hooks used while transferring the assets
 * @notice This facet contract contains all the external pre-hook functions related to seToken
 */
contract PolicyFacet is IPolicyFacet, SEFRewardsHelper {
    /// @notice Emitted when a new borrow-side SEF speed is calculated for a market
    event SegmentBorrowSpeedUpdated(SeToken indexed seToken, uint256 newSpeed);

    /// @notice Emitted when a new supply-side SEF speed is calculated for a market
    event SegmentSupplySpeedUpdated(SeToken indexed seToken, uint256 newSpeed);

    /**
     * @notice Checks if the account should be allowed to mint tokens in the given market
     * @param seToken The market to verify the mint against
     * @param minter The account which would get the minted tokens
     * @param mintAmount The amount of underlying being supplied to the market in exchange for tokens
     * @return 0 if the mint is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function mintAllowed(address seToken, address minter, uint256 mintAmount) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        checkProtocolPauseState();
        checkActionPauseState(seToken, Action.MINT);
        ensureListed(markets[seToken]);

        uint256 supplyCap = supplyCaps[seToken];
        require(supplyCap != 0, "market supply cap is 0");

        uint256 seTokenSupply = SeToken(seToken).totalSupply();
        Exp memory exchangeRate = Exp({ mantissa: SeToken(seToken).exchangeRateStored() });
        uint256 nextTotalSupply = mul_ScalarTruncateAddUInt(exchangeRate, seTokenSupply, mintAmount);
        require(nextTotalSupply <= supplyCap, "market supply cap reached");

        // Keep the flywheel moving
        updateSegmentSupplyIndex(seToken);
        distributeSupplierSegment(seToken, minter);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates mint and reverts on rejection. May emit logs.
     * @param seToken Asset being minted
     * @param minter The address minting the tokens
     * @param actualMintAmount The amount of the underlying asset being minted
     * @param mintTokens The number of tokens being minted
     */
    function mintVerify(address seToken, address minter, uint256 actualMintAmount, uint256 mintTokens) external {}

    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param seToken The market to verify the redeem against
     * @param redeemer The account which would redeem the tokens
     * @param redeemTokens The number of seTokens to exchange for the underlying asset in the market
     * @return 0 if the redeem is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function redeemAllowed(address seToken, address redeemer, uint256 redeemTokens) external returns (uint256) {
        checkProtocolPauseState();
        checkActionPauseState(seToken, Action.REDEEM);

        uint256 allowed = redeemAllowedInternal(seToken, redeemer, redeemTokens);
        if (allowed != uint256(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateSegmentSupplyIndex(seToken);
        distributeSupplierSegment(seToken, redeemer);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates redeem and reverts on rejection. May emit log
     * @param seToken Asset being redeemed
     * @param redeemer The address redeeming the tokens
     * @param redeemAmount The amount of the underlying asset being redeemed
     * @param redeemTokens The number of tokens being redeemed
     */
    // solhint-disable-next-line no-unused-vars
    function redeemVerify(address seToken, address redeemer, uint256 redeemAmount, uint256 redeemTokens) external pure {
        require(redeemTokens != 0 || redeemAmount == 0, "redeemTokens zero");
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param seToken The market to verify the borrow against
     * @param borrower The account which would borrow the asset
     * @param borrowAmount The amount of underlying the account would borrow
     * @return 0 if the borrow is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function borrowAllowed(address seToken, address borrower, uint256 borrowAmount) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        checkProtocolPauseState();
        checkActionPauseState(seToken, Action.BORROW);

        ensureListed(markets[seToken]);

        if (!markets[seToken].accountMembership[borrower]) {
            // only seTokens may call borrowAllowed if borrower not in market
            require(msg.sender == seToken, "sender must be seToken");

            // attempt to add borrower to the market
            Error err = addToMarketInternal(SeToken(seToken), borrower);
            if (err != Error.NO_ERROR) {
                return uint256(err);
            }
        }

        if (oracle.getUnderlyingPrice(SeToken(seToken)) == 0) {
            return uint256(Error.PRICE_ERROR);
        }

        uint256 borrowCap = borrowCaps[seToken];
        // Borrow cap of 0 corresponds to unlimited borrowing
        if (borrowCap != 0) {
            uint256 nextTotalBorrows = add_(SeToken(seToken).totalBorrows(), borrowAmount);
            require(nextTotalBorrows < borrowCap, "market borrow cap reached");
        }

        (Error err, , uint256 shortfall) = getHypotheticalAccountLiquidityInternal(
            borrower,
            SeToken(seToken),
            0,
            borrowAmount
        );
        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall != 0) {
            return uint256(Error.INSUFFICIENT_LIQUIDITY);
        }

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({ mantissa: SeToken(seToken).borrowIndex() });
        updateSegmentBorrowIndex(seToken, borrowIndex);
        distributeBorrowerSegment(seToken, borrower, borrowIndex);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates borrow and reverts on rejection. May emit log
     * @param seToken Asset whose underlying is being borrowed
     * @param borrower The address borrowing the underlying
     * @param borrowAmount The amount of the underlying asset requested to borrow
     */
    // solhint-disable-next-line no-unused-vars
    function borrowVerify(address seToken, address borrower, uint256 borrowAmount) external {}

    /**
     * @notice Checks if the account should be allowed to repay a borrow in the given market
     * @param seToken The market to verify the repay against
     * @param payer The account which would repay the asset
     * @param borrower The account which borrowed the asset
     * @param repayAmount The amount of the underlying asset the account would repay
     * @return 0 if the repay is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function repayBorrowAllowed(
        address seToken,
        // solhint-disable-next-line no-unused-vars
        address payer,
        address borrower,
        // solhint-disable-next-line no-unused-vars
        uint256 repayAmount
    ) external returns (uint256) {
        checkProtocolPauseState();
        checkActionPauseState(seToken, Action.REPAY);
        ensureListed(markets[seToken]);

        // Keep the flywheel moving
        Exp memory borrowIndex = Exp({ mantissa: SeToken(seToken).borrowIndex() });
        updateSegmentBorrowIndex(seToken, borrowIndex);
        distributeBorrowerSegment(seToken, borrower, borrowIndex);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates repayBorrow and reverts on rejection. May emit log
     * @param seToken Asset being repaid
     * @param payer The address repaying the borrow
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     */
    function repayBorrowVerify(
        address seToken,
        address payer,
        address borrower,
        uint256 actualRepayAmount,
        uint256 borrowerIndex
    ) external {}

    /**
     * @notice Checks if the liquidation should be allowed to occur
     * @param seTokenBorrowed Asset which was borrowed by the borrower
     * @param seTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param repayAmount The amount of underlying being repaid
     */
    function liquidateBorrowAllowed(
        address seTokenBorrowed,
        address seTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external view returns (uint256) {
        checkProtocolPauseState();

        // if we want to pause liquidating to seTokenCollateral, we should pause seizing
        checkActionPauseState(seTokenBorrowed, Action.LIQUIDATE);

        if (liquidatorContract != address(0) && liquidator != liquidatorContract) {
            return uint256(Error.UNAUTHORIZED);
        }

        ensureListed(markets[seTokenCollateral]);

        uint256 borrowBalance;
        if (address(seTokenBorrowed) != address(seusdController)) {
            ensureListed(markets[seTokenBorrowed]);
            borrowBalance = SeToken(seTokenBorrowed).borrowBalanceStored(borrower);
        } else {
            borrowBalance = seusdController.getSEUSDRepayAmount(borrower);
        }

        if (isForcedLiquidationEnabled[seTokenBorrowed]) {
            if (repayAmount > borrowBalance) {
                return uint(Error.TOO_MUCH_REPAY);
            }
            return uint(Error.NO_ERROR);
        }

        /* The borrower must have shortfall in order to be liquidatable */
        (Error err, , uint256 shortfall) = getHypotheticalAccountLiquidityInternal(borrower, SeToken(address(0)), 0, 0);
        if (err != Error.NO_ERROR) {
            return uint256(err);
        }
        if (shortfall == 0) {
            return uint256(Error.INSUFFICIENT_SHORTFALL);
        }

        // The liquidator may not repay more than what is allowed by the closeFactor
        //-- maxClose = multipy of closeFactorMantissa and borrowBalance
        if (repayAmount > mul_ScalarTruncate(Exp({ mantissa: closeFactorMantissa }), borrowBalance)) {
            return uint256(Error.TOO_MUCH_REPAY);
        }

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates liquidateBorrow and reverts on rejection. May emit logs.
     * @param seTokenBorrowed Asset which was borrowed by the borrower
     * @param seTokenCollateral Asset which was used as collateral and will be seized
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param actualRepayAmount The amount of underlying being repaid
     * @param seizeTokens The amount of collateral token that will be seized
     */
    function liquidateBorrowVerify(
        address seTokenBorrowed,
        address seTokenCollateral,
        address liquidator,
        address borrower,
        uint256 actualRepayAmount,
        uint256 seizeTokens
    ) external {}

    /**
     * @notice Checks if the seizing of assets should be allowed to occur
     * @param seTokenCollateral Asset which was used as collateral and will be seized
     * @param seTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    function seizeAllowed(
        address seTokenCollateral,
        address seTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens // solhint-disable-line no-unused-vars
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        checkProtocolPauseState();
        checkActionPauseState(seTokenCollateral, Action.SEIZE);

        Market storage market = markets[seTokenCollateral];

        // We've added SEUSDController as a borrowed token list check for seize
        ensureListed(market);

        if (!market.accountMembership[borrower]) {
            return uint256(Error.MARKET_NOT_COLLATERAL);
        }

        if (address(seTokenBorrowed) != address(seusdController)) {
            ensureListed(markets[seTokenBorrowed]);
        }

        if (SeToken(seTokenCollateral).comptroller() != SeToken(seTokenBorrowed).comptroller()) {
            return uint256(Error.COMPTROLLER_MISMATCH);
        }

        // Keep the flywheel moving
        updateSegmentSupplyIndex(seTokenCollateral);
        distributeSupplierSegment(seTokenCollateral, borrower);
        distributeSupplierSegment(seTokenCollateral, liquidator);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates seize and reverts on rejection. May emit log
     * @param seTokenCollateral Asset which was used as collateral and will be seized
     * @param seTokenBorrowed Asset which was borrowed by the borrower
     * @param liquidator The address repaying the borrow and seizing the collateral
     * @param borrower The address of the borrower
     * @param seizeTokens The number of collateral tokens to seize
     */
    // solhint-disable-next-line no-unused-vars
    function seizeVerify(
        address seTokenCollateral,
        address seTokenBorrowed,
        address liquidator,
        address borrower,
        uint256 seizeTokens
    ) external {}

    /**
     * @notice Checks if the account should be allowed to transfer tokens in the given market
     * @param seToken The market to verify the transfer against
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of seTokens to transfer
     * @return 0 if the transfer is allowed, otherwise a semi-opaque error code (See ErrorReporter.sol)
     */
    function transferAllowed(
        address seToken,
        address src,
        address dst,
        uint256 transferTokens
    ) external returns (uint256) {
        // Pausing is a very serious situation - we revert to sound the alarms
        checkProtocolPauseState();
        checkActionPauseState(seToken, Action.TRANSFER);

        // Currently the only consideration is whether or not
        //  the src is allowed to redeem this many tokens
        uint256 allowed = redeemAllowedInternal(seToken, src, transferTokens);
        if (allowed != uint256(Error.NO_ERROR)) {
            return allowed;
        }

        // Keep the flywheel moving
        updateSegmentSupplyIndex(seToken);
        distributeSupplierSegment(seToken, src);
        distributeSupplierSegment(seToken, dst);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Validates transfer and reverts on rejection. May emit log
     * @param seToken Asset being transferred
     * @param src The account which sources the tokens
     * @param dst The account which receives the tokens
     * @param transferTokens The number of seTokens to transfer
     */
    // solhint-disable-next-line no-unused-vars
    function transferVerify(address seToken, address src, address dst, uint256 transferTokens) external {}

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @return (possible error code (semi-opaque),
                account liquidity in excess of collateral requirements,
     *          account shortfall below collateral requirements)
     */
    function getAccountLiquidity(address account) external view returns (uint256, uint256, uint256) {
        (Error err, uint256 liquidity, uint256 shortfall) = getHypotheticalAccountLiquidityInternal(
            account,
            SeToken(address(0)),
            0,
            0
        );

        return (uint256(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param seTokenModify The market to hypothetically redeem/borrow in
     * @param account The account to determine liquidity for
     * @param redeemTokens The number of tokens to hypothetically redeem
     * @param borrowAmount The amount of underlying to hypothetically borrow
     * @return (possible error code (semi-opaque),
                hypothetical account liquidity in excess of collateral requirements,
     *          hypothetical account shortfall below collateral requirements)
     */
    function getHypotheticalAccountLiquidity(
        address account,
        address seTokenModify,
        uint256 redeemTokens,
        uint256 borrowAmount
    ) external view returns (uint256, uint256, uint256) {
        (Error err, uint256 liquidity, uint256 shortfall) = getHypotheticalAccountLiquidityInternal(
            account,
            SeToken(seTokenModify),
            redeemTokens,
            borrowAmount
        );
        return (uint256(err), liquidity, shortfall);
    }

    // setter functionality
    /**
     * @notice Set SEF speed for a single market
     * @dev Allows the contract admin to set SEF speed for a market
     * @param seTokens The market whose SEF speed to update
     * @param supplySpeeds New SEF speed for supply
     * @param borrowSpeeds New SEF speed for borrow
     */
    function _setSegmentSpeeds(
        SeToken[] calldata seTokens,
        uint256[] calldata supplySpeeds,
        uint256[] calldata borrowSpeeds
    ) external {
        ensureAdmin();

        uint256 numTokens = seTokens.length;
        require(numTokens == supplySpeeds.length && numTokens == borrowSpeeds.length, "invalid input");

        for (uint256 i; i < numTokens; ++i) {
            ensureNonzeroAddress(address(seTokens[i]));
            setSegmentSpeedInternal(seTokens[i], supplySpeeds[i], borrowSpeeds[i]);
        }
    }

    function setSegmentSpeedInternal(SeToken seToken, uint256 supplySpeed, uint256 borrowSpeed) internal {
        ensureListed(markets[address(seToken)]);

        if (segmentSupplySpeeds[address(seToken)] != supplySpeed) {
            // Supply speed updated so let's update supply state to ensure that
            //  1. SEF accrued properly for the old speed, and
            //  2. SEF accrued at the new speed starts after this block.

            updateSegmentSupplyIndex(address(seToken));
            // Update speed and emit event
            segmentSupplySpeeds[address(seToken)] = supplySpeed;
            emit SegmentSupplySpeedUpdated(seToken, supplySpeed);
        }

        if (segmentBorrowSpeeds[address(seToken)] != borrowSpeed) {
            // Borrow speed updated so let's update borrow state to ensure that
            //  1. SEF accrued properly for the old speed, and
            //  2. SEF accrued at the new speed starts after this block.
            Exp memory borrowIndex = Exp({ mantissa: seToken.borrowIndex() });
            updateSegmentBorrowIndex(address(seToken), borrowIndex);

            // Update speed and emit event
            segmentBorrowSpeeds[address(seToken)] = borrowSpeed;
            emit SegmentBorrowSpeedUpdated(seToken, borrowSpeed);
        }
    }
}
