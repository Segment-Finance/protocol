// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { IRewardFacet } from "../interfaces/IRewardFacet.sol";
import { SEFRewardsHelper, SeToken } from "./SEFRewardsHelper.sol";
import { SafeBEP20, IBEP20 } from "../../../Utils/SafeBEP20.sol";
import { SeBep20Interface } from "../../../Tokens/SeTokens/SeTokenInterfaces.sol";
import "../../../Swap/lib/TransferHelper.sol";

/**
 * @title RewardFacet
 * @author Segment
 * @dev This facet contains all the methods related to the reward functionality
 * @notice This facet contract provides the external functions related to all claims and rewards of the protocol
 */
contract RewardFacet is IRewardFacet, SEFRewardsHelper {
    /// @notice Emitted when Segment is granted by admin
    event SegmentGranted(address indexed recipient, uint256 amount);

    using SafeBEP20 for IBEP20;

    /**
     * @notice Claim all the sef accrued by holder in all markets and SEUSD
     * @param holder The address to claim SEF for
     */
    function claimSegment(address holder) public {
        return claimSegment(holder, allMarkets);
    }

    /**
     * @notice Claim all the sef accrued by holder in the specified markets
     * @param holder The address to claim SEF for
     * @param seTokens The list of markets to claim SEF in
     */
    function claimSegment(address holder, SeToken[] memory seTokens) public {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimSegment(holders, seTokens, true, true);
    }

    /**
     * @notice Claim all sef accrued by the holders
     * @param holders The addresses to claim SEF for
     * @param seTokens The list of markets to claim SEF in
     * @param borrowers Whether or not to claim SEF earned by borrowing
     * @param suppliers Whether or not to claim SEF earned by supplying
     */
    function claimSegment(address[] memory holders, SeToken[] memory seTokens, bool borrowers, bool suppliers) public {
        claimSegment(holders, seTokens, borrowers, suppliers, false);
    }

    /**
     * @notice Claim all the sef accrued by holder in all markets, a shorthand for `claimSegment` with collateral set to `true`
     * @param holder The address to claim SEF for
     */
    function claimSegmentAsCollateral(address holder) external {
        address[] memory holders = new address[](1);
        holders[0] = holder;
        claimSegment(holders, allMarkets, true, true, true);
    }

    /**
     * @notice Transfer SEF to the user with user's shortfall considered
     * @dev Note: If there is not enough SEF, we do not perform the transfer all
     * @param user The address of the user to transfer SEF to
     * @param amount The amount of SEF to (possibly) transfer
     * @param shortfall The shortfall of the user
     * @param collateral Whether or not we will use user's segment reward as collateral to pay off the debt
     * @return The amount of SEF which was NOT transferred to the user
     */
    function grantSEFInternal(
        address user,
        uint256 amount,
        uint256 shortfall,
        bool collateral
    ) internal returns (uint256) {
        if (_sefToken == address(0)) {
            // Allocation is not enabled yet
            return 0;
        }

        if (amount == 0 || amount > IBEP20(_sefToken).balanceOf(address(this))) {
            return amount;
        }

        if (shortfall == 0) {
            IBEP20(_sefToken).safeTransfer(user, amount);
            return 0;
        }
        // If user's bankrupt and doesn't use pending sef as collateral, don't grant
        // anything, otherwise, we will transfer the pending sef as collateral to
        // seSEF token and mint seSEF for the user
        //
        // If mintBehalf failed, don't grant any sef
        require(collateral, "bankrupt");

        if (_seSefToken != address(0)) {
            TransferHelper.safeApprove(_sefToken, _seSefToken, 0);
            TransferHelper.safeApprove(_sefToken, _seSefToken, amount);
            require(
                SeBep20Interface(_seSefToken).mintBehalf(user, amount) == uint256(Error.NO_ERROR),
                "mint behalf error"
            );
        }

        // set segmentAccrued[user] to 0
        return 0;
    }

    /*** Segment Distribution Admin ***/

    /**
     * @notice Transfer SEF to the recipient
     * @dev Allows the contract admin to transfer SEF to any recipient based on the recipient's shortfall
     *      Note: If there is not enough SEF, we do not perform the transfer all
     * @param recipient The address of the recipient to transfer SEF to
     * @param amount The amount of SEF to (possibly) transfer
     */
    function _grantSEF(address recipient, uint256 amount) external {
        ensureAdmin();
        uint256 amountLeft = grantSEFInternal(recipient, amount, 0, false);
        require(amountLeft == 0, "no sef");
        emit SegmentGranted(recipient, amount);
    }

    /**
     * @notice Return the address of the SEF seToken
     * @return The address of SEF seToken
     */
    function getSEFSeTokenAddress() public view returns (address) {
        return _seSefToken;
    }

    /**
     * @notice Claim all sef accrued by the holders
     * @param holders The addresses to claim SEF for
     * @param seTokens The list of markets to claim SEF in
     * @param borrowers Whether or not to claim SEF earned by borrowing
     * @param suppliers Whether or not to claim SEF earned by supplying
     * @param collateral Whether or not to use SEF earned as collateral, only takes effect when the holder has a shortfall
     */
    function claimSegment(
        address[] memory holders,
        SeToken[] memory seTokens,
        bool borrowers,
        bool suppliers,
        bool collateral
    ) public {
        uint256 j;
        uint256 holdersLength = holders.length;
        uint256 seTokensLength = seTokens.length;
        for (uint256 i; i < seTokensLength; ++i) {
            SeToken seToken = seTokens[i];
            ensureListed(markets[address(seToken)]);
            if (borrowers) {
                Exp memory borrowIndex = Exp({ mantissa: seToken.borrowIndex() });
                updateSegmentBorrowIndex(address(seToken), borrowIndex);
                for (j = 0; j < holdersLength; ++j) {
                    distributeBorrowerSegment(address(seToken), holders[j], borrowIndex);
                }
            }
            if (suppliers) {
                updateSegmentSupplyIndex(address(seToken));
                for (j = 0; j < holdersLength; ++j) {
                    distributeSupplierSegment(address(seToken), holders[j]);
                }
            }
        }

        for (j = 0; j < holdersLength; ++j) {
            address holder = holders[j];
            // If there is a positive shortfall, the SEF reward is accrued,
            // but won't be granted to this holder
            (, , uint256 shortfall) = getHypotheticalAccountLiquidityInternal(holder, SeToken(address(0)), 0, 0);

            uint256 value = segmentAccrued[holder];
            segmentAccrued[holder] = 0;

            uint256 returnAmount = grantSEFInternal(holder, value, shortfall, collateral);

            // returnAmount can only be positive if balance of sefAddress is less than grant amount(segmentAccrued[holder])
            if (returnAmount != 0) {
                segmentAccrued[holder] = returnAmount;
            }
        }
    }
}
