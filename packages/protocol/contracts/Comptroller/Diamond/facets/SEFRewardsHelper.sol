// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { FacetBase, SeToken } from "./FacetBase.sol";

/**
 * @title SEFRewardsHelper
 * @author Segment
 * @dev This contract contains internal functions used in RewardFacet and PolicyFacet
 * @notice This facet contract contains the shared functions used by the RewardFacet and PolicyFacet
 */
contract SEFRewardsHelper is FacetBase {
    /// @notice Emitted when SEF is distributed to a borrower
    event DistributedBorrowerSegment(
        SeToken indexed seToken,
        address indexed borrower,
        uint256 segmentDelta,
        uint256 segmentBorrowIndex
    );

    /// @notice Emitted when SEF is distributed to a supplier
    event DistributedSupplierSegment(
        SeToken indexed seToken,
        address indexed supplier,
        uint256 segmentDelta,
        uint256 segmentSupplyIndex
    );

    /**
     * @notice Accrue SEF to the market by updating the borrow index
     * @param seToken The market whose borrow index to update
     */
    function updateSegmentBorrowIndex(address seToken, Exp memory marketBorrowIndex) internal {
        SegmentMarketState storage borrowState = segmentBorrowState[seToken];
        uint256 borrowSpeed = segmentBorrowSpeeds[seToken];
        uint32 blockNumber = getBlockNumberAsUint32();
        uint256 deltaBlocks = sub_(blockNumber, borrowState.block);
        if (deltaBlocks != 0 && borrowSpeed != 0) {
            uint256 borrowAmount = div_(SeToken(seToken).totalBorrows(), marketBorrowIndex);
            uint256 accruedSegment = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount != 0 ? fraction(accruedSegment, borrowAmount) : Double({ mantissa: 0 });
            borrowState.index = safe224(add_(Double({ mantissa: borrowState.index }), ratio).mantissa, "224");
            borrowState.block = blockNumber;
        } else if (deltaBlocks != 0) {
            borrowState.block = blockNumber;
        }
    }

    /**
     * @notice Accrue SEF to the market by updating the supply index
     * @param seToken The market whose supply index to update
     */
    function updateSegmentSupplyIndex(address seToken) internal {
        SegmentMarketState storage supplyState = segmentSupplyState[seToken];
        uint256 supplySpeed = segmentSupplySpeeds[seToken];
        uint32 blockNumber = getBlockNumberAsUint32();

        uint256 deltaBlocks = sub_(blockNumber, supplyState.block);
        if (deltaBlocks != 0 && supplySpeed != 0) {
            uint256 supplyTokens = SeToken(seToken).totalSupply();
            uint256 accruedSegment = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens != 0 ? fraction(accruedSegment, supplyTokens) : Double({ mantissa: 0 });
            supplyState.index = safe224(add_(Double({ mantissa: supplyState.index }), ratio).mantissa, "224");
            supplyState.block = blockNumber;
        } else if (deltaBlocks != 0) {
            supplyState.block = blockNumber;
        }
    }

    /**
     * @notice Calculate SEF accrued by a supplier and possibly transfer it to them
     * @param seToken The market in which the supplier is interacting
     * @param supplier The address of the supplier to distribute SEF to
     */
    function distributeSupplierSegment(address seToken, address supplier) internal {
        if (address(seusdVaultAddress) != address(0)) {
            releaseToVault();
        }
        uint256 supplyIndex = segmentSupplyState[seToken].index;
        uint256 supplierIndex = segmentSupplierIndex[seToken][supplier];
        // Update supplier's index to the current index since we are distributing accrued SEF
        segmentSupplierIndex[seToken][supplier] = supplyIndex;
        if (supplierIndex == 0 && supplyIndex >= segmentInitialIndex) {
            // Covers the case where users supplied tokens before the market's supply state index was set.
            // Rewards the user with SEF accrued from the start of when supplier rewards were first
            // set for the market.
            supplierIndex = segmentInitialIndex;
        }
        // Calculate change in the cumulative sum of the SEF per seToken accrued
        Double memory deltaIndex = Double({ mantissa: sub_(supplyIndex, supplierIndex) });
        // Multiply of supplierTokens and supplierDelta
        uint256 supplierDelta = mul_(SeToken(seToken).balanceOf(supplier), deltaIndex);
        // Addition of supplierAccrued and supplierDelta
        segmentAccrued[supplier] = add_(segmentAccrued[supplier], supplierDelta);
        emit DistributedSupplierSegment(SeToken(seToken), supplier, supplierDelta, supplyIndex);
    }

    /**
     * @notice Calculate SEF accrued by a borrower and possibly transfer it to them
     * @dev Borrowers will not begin to accrue until after the first interaction with the protocol
     * @param seToken The market in which the borrower is interacting
     * @param borrower The address of the borrower to distribute SEF to
     */
    function distributeBorrowerSegment(address seToken, address borrower, Exp memory marketBorrowIndex) internal {
        if (address(seusdVaultAddress) != address(0)) {
            releaseToVault();
        }
        uint256 borrowIndex = segmentBorrowState[seToken].index;
        uint256 borrowerIndex = segmentBorrowerIndex[seToken][borrower];
        // Update borrowers's index to the current index since we are distributing accrued SEF
        segmentBorrowerIndex[seToken][borrower] = borrowIndex;
        if (borrowerIndex == 0 && borrowIndex >= segmentInitialIndex) {
            // Covers the case where users borrowed tokens before the market's borrow state index was set.
            // Rewards the user with SEF accrued from the start of when borrower rewards were first
            // set for the market.
            borrowerIndex = segmentInitialIndex;
        }
        // Calculate change in the cumulative sum of the SEF per borrowed unit accrued
        Double memory deltaIndex = Double({ mantissa: sub_(borrowIndex, borrowerIndex) });
        uint256 borrowerDelta = mul_(div_(SeToken(seToken).borrowBalanceStored(borrower), marketBorrowIndex), deltaIndex);
        segmentAccrued[borrower] = add_(segmentAccrued[borrower], borrowerDelta);
        emit DistributedBorrowerSegment(SeToken(seToken), borrower, borrowerDelta, borrowIndex);
    }
}
