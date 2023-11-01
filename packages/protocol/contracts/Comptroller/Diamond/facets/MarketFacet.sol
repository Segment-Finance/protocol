// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { IMarketFacet } from "../interfaces/IMarketFacet.sol";
import { FacetBase, SeToken } from "./FacetBase.sol";

/**
 * @title MarketFacet
 * @author Segment
 * @dev This facet contains all the methods related to the market's management in the pool
 * @notice This facet contract contains functions regarding markets
 */
contract MarketFacet is IMarketFacet, FacetBase {
    /// @notice Emitted when an admin supports a market
    event MarketListed(SeToken indexed seToken);

    /// @notice Emitted when an account exits a market
    event MarketExited(SeToken indexed seToken, address indexed account);

    /// @notice Emitted when the borrowing delegate rights are updated for an account
    event DelegateUpdated(address indexed borrower, address indexed delegate, bool allowDelegatedBorrows);

    /// @notice Indicator that this is a Comptroller contract (for inspection)
    function isComptroller() public pure returns (bool) {
        return true;
    }

    /**
     * @notice Returns the assets an account has entered
     * @param account The address of the account to pull assets for
     * @return A dynamic list with the assets the account has entered
     */
    function getAssetsIn(address account) external view returns (SeToken[] memory) {
        return accountAssets[account];
    }

    /**
     * @notice Return all of the markets
     * @dev The automatic getter may be used to access an individual market
     * @return The list of market addresses
     */
    function getAllMarkets() external view returns (SeToken[] memory) {
        return allMarkets;
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in seToken.liquidateBorrowFresh)
     * @param seTokenBorrowed The address of the borrowed seToken
     * @param seTokenCollateral The address of the collateral seToken
     * @param actualRepayAmount The amount of seTokenBorrowed underlying to convert into seTokenCollateral tokens
     * @return (errorCode, number of seTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateCalculateSeizeTokens(
        address seTokenBorrowed,
        address seTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256) {
        (uint256 err, uint256 seizeTokens) = comptrollerLens.liquidateCalculateSeizeTokens(
            address(this),
            seTokenBorrowed,
            seTokenCollateral,
            actualRepayAmount
        );
        return (err, seizeTokens);
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev Used in liquidation (called in seToken.liquidateBorrowFresh)
     * @param seTokenCollateral The address of the collateral seToken
     * @param actualRepayAmount The amount of seTokenBorrowed underlying to convert into seTokenCollateral tokens
     * @return (errorCode, number of seTokenCollateral tokens to be seized in a liquidation)
     */
    function liquidateSEUSDCalculateSeizeTokens(
        address seTokenCollateral,
        uint256 actualRepayAmount
    ) external view returns (uint256, uint256) {
        (uint256 err, uint256 seizeTokens) = comptrollerLens.liquidateSEUSDCalculateSeizeTokens(
            address(this),
            seTokenCollateral,
            actualRepayAmount
        );
        return (err, seizeTokens);
    }

    /**
     * @notice Returns whether the given account is entered in the given asset
     * @param account The address of the account to check
     * @param seToken The seToken to check
     * @return True if the account is in the asset, otherwise false
     */
    function checkMembership(address account, SeToken seToken) external view returns (bool) {
        return markets[address(seToken)].accountMembership[account];
    }

    /**
     * @notice Add assets to be included in account liquidity calculation
     * @param seTokens The list of addresses of the seToken markets to be enabled
     * @return Success indicator for whether each corresponding market was entered
     */
    function enterMarkets(address[] calldata seTokens) external returns (uint256[] memory) {
        uint256 len = seTokens.length;

        uint256[] memory results = new uint256[](len);
        for (uint256 i; i < len; ++i) {
            results[i] = uint256(addToMarketInternal(SeToken(seTokens[i]), msg.sender));
        }

        return results;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @dev Sender must not have an outstanding borrow balance in the asset,
     *  or be providing necessary collateral for an outstanding borrow
     * @param seTokenAddress The address of the asset to be removed
     * @return Whether or not the account successfully exited the market
     */
    function exitMarket(address seTokenAddress) external returns (uint256) {
        checkActionPauseState(seTokenAddress, Action.EXIT_MARKET);

        SeToken seToken = SeToken(seTokenAddress);
        /* Get sender tokensHeld and amountOwed underlying from the seToken */
        (uint256 oErr, uint256 tokensHeld, uint256 amountOwed, ) = seToken.getAccountSnapshot(msg.sender);
        require(oErr == 0, "getAccountSnapshot failed"); // semi-opaque error code

        /* Fail if the sender has a borrow balance */
        if (amountOwed != 0) {
            return fail(Error.NONZERO_BORROW_BALANCE, FailureInfo.EXIT_MARKET_BALANCE_OWED);
        }

        /* Fail if the sender is not permitted to redeem all of their tokens */
        uint256 allowed = redeemAllowedInternal(seTokenAddress, msg.sender, tokensHeld);
        if (allowed != 0) {
            return failOpaque(Error.REJECTION, FailureInfo.EXIT_MARKET_REJECTION, allowed);
        }

        Market storage marketToExit = markets[address(seToken)];

        /* Return true if the sender is not already ‘in’ the market */
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint256(Error.NO_ERROR);
        }

        /* Set seToken account membership to false */
        delete marketToExit.accountMembership[msg.sender];

        /* Delete seToken from the account’s list of assets */
        // In order to delete seToken, copy last item in list to location of item to be removed, reduce length by 1
        SeToken[] storage userAssetList = accountAssets[msg.sender];
        uint256 len = userAssetList.length;
        uint256 i;
        for (; i < len; ++i) {
            if (userAssetList[i] == seToken) {
                userAssetList[i] = userAssetList[len - 1];
                userAssetList.pop();
                break;
            }
        }

        // We *must* have found the asset in the list or our redundant data structure is broken
        assert(i < len);

        emit MarketExited(seToken, msg.sender);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Add the market to the markets mapping and set it as listed
     * @dev Allows a privileged role to add and list markets to the Comptroller
     * @param seToken The address of the market (token) to list
     * @return uint256 0=success, otherwise a failure. (See enum Error for details)
     */
    function _supportMarket(SeToken seToken) external returns (uint256) {
        ensureAllowed("_supportMarket(address)");

        if (markets[address(seToken)].isListed) {
            return fail(Error.MARKET_ALREADY_LISTED, FailureInfo.SUPPORT_MARKET_EXISTS);
        }

        seToken.isSeToken(); // Sanity check to make sure its really a SeToken

        // Note that isSegment is not in active use anymore
        Market storage newMarket = markets[address(seToken)];
        newMarket.isListed = true;
        newMarket.isSegment = false;
        newMarket.collateralFactorMantissa = 0;

        _addMarketInternal(seToken);
        _initializeMarket(address(seToken));

        emit MarketListed(seToken);

        return uint256(Error.NO_ERROR);
    }

    /**
     * @notice Grants or revokes the borrowing delegate rights to / from an account
     *  If allowed, the delegate will be able to borrow funds on behalf of the sender
     *  Upon a delegated borrow, the delegate will receive the funds, and the borrower
     *  will see the debt on their account
     * @param delegate The address to update the rights for
     * @param allowBorrows Whether to grant (true) or revoke (false) the rights
     */
    function updateDelegate(address delegate, bool allowBorrows) external {
        _updateDelegate(msg.sender, delegate, allowBorrows);
    }

    function _updateDelegate(address borrower, address delegate, bool allowBorrows) internal {
        approvedDelegates[borrower][delegate] = allowBorrows;
        emit DelegateUpdated(borrower, delegate, allowBorrows);
    }

    function _addMarketInternal(SeToken seToken) internal {
        uint256 allMarketsLength = allMarkets.length;
        for (uint256 i; i < allMarketsLength; ++i) {
            require(allMarkets[i] != seToken, "already added");
        }
        allMarkets.push(seToken);
    }

    function _initializeMarket(address seToken) internal {
        uint32 blockNumber = getBlockNumberAsUint32();

        SegmentMarketState storage supplyState = segmentSupplyState[seToken];
        SegmentMarketState storage borrowState = segmentBorrowState[seToken];

        /*
         * Update market state indices
         */
        if (supplyState.index == 0) {
            // Initialize supply state index with default value
            supplyState.index = segmentInitialIndex;
        }

        if (borrowState.index == 0) {
            // Initialize borrow state index with default value
            borrowState.index = segmentInitialIndex;
        }

        /*
         * Update market state block numbers
         */
        supplyState.block = borrowState.block = blockNumber;
    }
}
