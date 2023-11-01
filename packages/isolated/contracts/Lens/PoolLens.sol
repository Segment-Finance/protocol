// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { ResilientOracleInterface } from "../../../oracle/contracts/interfaces/OracleInterface.sol";

import { ExponentialNoError } from "../ExponentialNoError.sol";
import { SeToken } from "../SeToken.sol";
import { ComptrollerInterface, ComptrollerViewInterface } from "../ComptrollerInterface.sol";
import { PoolRegistryInterface } from "../Pool/PoolRegistryInterface.sol";
import { PoolRegistry } from "../Pool/PoolRegistry.sol";
import { RewardsDistributor } from "../Rewards/RewardsDistributor.sol";

/**
 * @title PoolLens
 * @notice The `PoolLens` contract is designed to retrieve important information for each registered pool. A list of essential information
 * for all pools within the lending protocol can be acquired through the function `getAllPools()`. Additionally, the following records can be
 * looked up for specific pools and markets:
- the seToken balance of a given user;
- the pool data (oracle address, associated seToken, liquidation incentive, etc) of a pool via its associated comptroller address;
- the seToken address in a pool for a given asset;
- a list of all pools that support an asset;
- the underlying asset price of a seToken;
- the metadata (exchange/borrow/supply rate, total supply, collateral factor, etc) of any seToken.
 */
contract PoolLens is ExponentialNoError {
    /**
     * @dev Struct for PoolDetails.
     */
    struct PoolData {
        string name;
        address creator;
        address comptroller;
        uint256 blockPosted;
        uint256 timestampPosted;
        string category;
        string logoURL;
        string description;
        address priceOracle;
        uint256 closeFactor;
        uint256 liquidationIncentive;
        uint256 minLiquidatableCollateral;
        SeTokenMetadata[] seTokens;
    }

    /**
     * @dev Struct for SeToken.
     */
    struct SeTokenMetadata {
        address seToken;
        uint256 exchangeRateCurrent;
        uint256 supplyRatePerBlock;
        uint256 borrowRatePerBlock;
        uint256 reserveFactorMantissa;
        uint256 supplyCaps;
        uint256 borrowCaps;
        uint256 totalBorrows;
        uint256 totalReserves;
        uint256 totalSupply;
        uint256 totalCash;
        bool isListed;
        uint256 collateralFactorMantissa;
        address underlyingAssetAddress;
        uint256 seTokenDecimals;
        uint256 underlyingDecimals;
    }

    /**
     * @dev Struct for SeTokenBalance.
     */
    struct SeTokenBalances {
        address seToken;
        uint256 balanceOf;
        uint256 borrowBalanceCurrent;
        uint256 balanceOfUnderlying;
        uint256 tokenBalance;
        uint256 tokenAllowance;
    }

    /**
     * @dev Struct for underlyingPrice of SeToken.
     */
    struct SeTokenUnderlyingPrice {
        address seToken;
        uint256 underlyingPrice;
    }

    /**
     * @dev Struct with pending reward info for a market.
     */
    struct PendingReward {
        address seTokenAddress;
        uint256 amount;
    }

    /**
     * @dev Struct with reward distribution totals for a single reward token and distributor.
     */
    struct RewardSummary {
        address distributorAddress;
        address rewardTokenAddress;
        uint256 totalRewards;
        PendingReward[] pendingRewards;
    }

    /**
     * @dev Struct used in RewardDistributor to save last updated market state.
     */
    struct RewardTokenState {
        // The market's last updated rewardTokenBorrowIndex or rewardTokenSupplyIndex
        uint224 index;
        // The block number the index was last updated at
        uint32 block;
        // The block number at which to stop rewards
        uint32 lastRewardingBlock;
    }

    /**
     * @dev Struct with bad debt of a market denominated
     */
    struct BadDebt {
        address seTokenAddress;
        uint256 badDebtUsd;
    }

    /**
     * @dev Struct with bad debt total denominated in usd for a pool and an array of BadDebt structs for each market
     */
    struct BadDebtSummary {
        address comptroller;
        uint256 totalBadDebtUsd;
        BadDebt[] badDebts;
    }

    /**
     * @notice Queries the user's supply/borrow balances in seTokens
     * @param seTokens The list of seToken addresses
     * @param account The user Account
     * @return A list of structs containing balances data
     */
    function seTokenBalancesAll(SeToken[] calldata seTokens, address account) external returns (SeTokenBalances[] memory) {
        uint256 seTokenCount = seTokens.length;
        SeTokenBalances[] memory res = new SeTokenBalances[](seTokenCount);
        for (uint256 i; i < seTokenCount; ++i) {
            res[i] = seTokenBalances(seTokens[i], account);
        }
        return res;
    }

    /**
     * @notice Queries all pools with addtional details for each of them
     * @dev This function is not designed to be called in a transaction: it is too gas-intensive
     * @param poolRegistryAddress The address of the PoolRegistry contract
     * @return Arrays of all Segment pools' data
     */
    function getAllPools(address poolRegistryAddress) external view returns (PoolData[] memory) {
        PoolRegistryInterface poolRegistryInterface = PoolRegistryInterface(poolRegistryAddress);
        PoolRegistry.SegmentPool[] memory segmentPools = poolRegistryInterface.getAllPools();
        uint256 poolLength = segmentPools.length;

        PoolData[] memory poolDataItems = new PoolData[](poolLength);

        for (uint256 i; i < poolLength; ++i) {
            PoolRegistry.SegmentPool memory segmentPool = segmentPools[i];
            PoolData memory poolData = getPoolDataFromSegmentPool(poolRegistryAddress, segmentPool);
            poolDataItems[i] = poolData;
        }

        return poolDataItems;
    }

    /**
     * @notice Queries the details of a pool identified by Comptroller address
     * @param poolRegistryAddress The address of the PoolRegistry contract
     * @param comptroller The Comptroller implementation address
     * @return PoolData structure containing the details of the pool
     */
    function getPoolByComptroller(
        address poolRegistryAddress,
        address comptroller
    ) external view returns (PoolData memory) {
        PoolRegistryInterface poolRegistryInterface = PoolRegistryInterface(poolRegistryAddress);
        return getPoolDataFromSegmentPool(poolRegistryAddress, poolRegistryInterface.getPoolByComptroller(comptroller));
    }

    /**
     * @notice Returns seToken holding the specified underlying asset in the specified pool
     * @param poolRegistryAddress The address of the PoolRegistry contract
     * @param comptroller The pool comptroller
     * @param asset The underlyingAsset of SeToken
     * @return Address of the seToken
     */
    function getSeTokenForAsset(
        address poolRegistryAddress,
        address comptroller,
        address asset
    ) external view returns (address) {
        PoolRegistryInterface poolRegistryInterface = PoolRegistryInterface(poolRegistryAddress);
        return poolRegistryInterface.getSeTokenForAsset(comptroller, asset);
    }

    /**
     * @notice Returns all pools that support the specified underlying asset
     * @param poolRegistryAddress The address of the PoolRegistry contract
     * @param asset The underlying asset of seToken
     * @return A list of Comptroller contracts
     */
    function getPoolsSupportedByAsset(
        address poolRegistryAddress,
        address asset
    ) external view returns (address[] memory) {
        PoolRegistryInterface poolRegistryInterface = PoolRegistryInterface(poolRegistryAddress);
        return poolRegistryInterface.getPoolsSupportedByAsset(asset);
    }

    /**
     * @notice Returns the price data for the underlying assets of the specified seTokens
     * @param seTokens The list of seToken addresses
     * @return An array containing the price data for each asset
     */
    function seTokenUnderlyingPriceAll(
        SeToken[] calldata seTokens
    ) external view returns (SeTokenUnderlyingPrice[] memory) {
        uint256 seTokenCount = seTokens.length;
        SeTokenUnderlyingPrice[] memory res = new SeTokenUnderlyingPrice[](seTokenCount);
        for (uint256 i; i < seTokenCount; ++i) {
            res[i] = seTokenUnderlyingPrice(seTokens[i]);
        }
        return res;
    }

    /**
     * @notice Returns the pending rewards for a user for a given pool.
     * @param account The user account.
     * @param comptrollerAddress address
     * @return Pending rewards array
     */
    function getPendingRewards(
        address account,
        address comptrollerAddress
    ) external view returns (RewardSummary[] memory) {
        SeToken[] memory markets = ComptrollerInterface(comptrollerAddress).getAllMarkets();
        RewardsDistributor[] memory rewardsDistributors = ComptrollerViewInterface(comptrollerAddress)
            .getRewardDistributors();
        RewardSummary[] memory rewardSummary = new RewardSummary[](rewardsDistributors.length);
        for (uint256 i; i < rewardsDistributors.length; ++i) {
            RewardSummary memory reward;
            reward.distributorAddress = address(rewardsDistributors[i]);
            reward.rewardTokenAddress = address(rewardsDistributors[i].rewardToken());
            reward.totalRewards = rewardsDistributors[i].rewardTokenAccrued(account);
            reward.pendingRewards = _calculateNotDistributedAwards(account, markets, rewardsDistributors[i]);
            rewardSummary[i] = reward;
        }
        return rewardSummary;
    }

    /**
     * @notice Returns a summary of a pool's bad debt broken down by market
     *
     * @param comptrollerAddress Address of the comptroller
     *
     * @return badDebtSummary A struct with comptroller address, total bad debut denominated in usd, and
     *   a break down of bad debt by market
     */
    function getPoolBadDebt(address comptrollerAddress) external view returns (BadDebtSummary memory) {
        uint256 totalBadDebtUsd;

        // Get every market in the pool
        ComptrollerViewInterface comptroller = ComptrollerViewInterface(comptrollerAddress);
        SeToken[] memory markets = comptroller.getAllMarkets();
        ResilientOracleInterface priceOracle = comptroller.oracle();

        BadDebt[] memory badDebts = new BadDebt[](markets.length);

        BadDebtSummary memory badDebtSummary;
        badDebtSummary.comptroller = comptrollerAddress;
        badDebtSummary.badDebts = badDebts;

        // // Calculate the bad debt is USD per market
        for (uint256 i; i < markets.length; ++i) {
            BadDebt memory badDebt;
            badDebt.seTokenAddress = address(markets[i]);
            badDebt.badDebtUsd =
                (SeToken(address(markets[i])).badDebt() * priceOracle.getUnderlyingPrice(address(markets[i]))) /
                EXP_SCALE;
            badDebtSummary.badDebts[i] = badDebt;
            totalBadDebtUsd = totalBadDebtUsd + badDebt.badDebtUsd;
        }

        badDebtSummary.totalBadDebtUsd = totalBadDebtUsd;

        return badDebtSummary;
    }

    /**
     * @notice Queries the user's supply/borrow balances in the specified seToken
     * @param seToken seToken address
     * @param account The user Account
     * @return A struct containing the balances data
     */
    function seTokenBalances(SeToken seToken, address account) public returns (SeTokenBalances memory) {
        uint256 balanceOf = seToken.balanceOf(account);
        uint256 borrowBalanceCurrent = seToken.borrowBalanceCurrent(account);
        uint256 balanceOfUnderlying = seToken.balanceOfUnderlying(account);
        uint256 tokenBalance;
        uint256 tokenAllowance;

        IERC20 underlying = IERC20(seToken.underlying());
        tokenBalance = underlying.balanceOf(account);
        tokenAllowance = underlying.allowance(account, address(seToken));

        return
            SeTokenBalances({
                seToken: address(seToken),
                balanceOf: balanceOf,
                borrowBalanceCurrent: borrowBalanceCurrent,
                balanceOfUnderlying: balanceOfUnderlying,
                tokenBalance: tokenBalance,
                tokenAllowance: tokenAllowance
            });
    }

    /**
     * @notice Queries additional information for the pool
     * @param poolRegistryAddress Address of the PoolRegistry
     * @param segmentPool The SegmentPool Object from PoolRegistry
     * @return Enriched PoolData
     */
    function getPoolDataFromSegmentPool(
        address poolRegistryAddress,
        PoolRegistry.SegmentPool memory segmentPool
    ) public view returns (PoolData memory) {
        // Get tokens in the Pool
        ComptrollerInterface comptrollerInstance = ComptrollerInterface(segmentPool.comptroller);

        SeToken[] memory seTokens = comptrollerInstance.getAllMarkets();

        SeTokenMetadata[] memory seTokenMetadataItems = seTokenMetadataAll(seTokens);

        PoolRegistryInterface poolRegistryInterface = PoolRegistryInterface(poolRegistryAddress);

        PoolRegistry.SegmentPoolMetaData memory segmentPoolMetaData = poolRegistryInterface.getSegmentPoolMetadata(
            segmentPool.comptroller
        );

        ComptrollerViewInterface comptrollerViewInstance = ComptrollerViewInterface(segmentPool.comptroller);

        PoolData memory poolData = PoolData({
            name: segmentPool.name,
            creator: segmentPool.creator,
            comptroller: segmentPool.comptroller,
            blockPosted: segmentPool.blockPosted,
            timestampPosted: segmentPool.timestampPosted,
            category: segmentPoolMetaData.category,
            logoURL: segmentPoolMetaData.logoURL,
            description: segmentPoolMetaData.description,
            seTokens: seTokenMetadataItems,
            priceOracle: address(comptrollerViewInstance.oracle()),
            closeFactor: comptrollerViewInstance.closeFactorMantissa(),
            liquidationIncentive: comptrollerViewInstance.liquidationIncentiveMantissa(),
            minLiquidatableCollateral: comptrollerViewInstance.minLiquidatableCollateral()
        });

        return poolData;
    }

    /**
     * @notice Returns the metadata of SeToken
     * @param seToken The address of seToken
     * @return SeTokenMetadata struct
     */
    function seTokenMetadata(SeToken seToken) public view returns (SeTokenMetadata memory) {
        uint256 exchangeRateCurrent = seToken.exchangeRateStored();
        address comptrollerAddress = address(seToken.comptroller());
        ComptrollerViewInterface comptroller = ComptrollerViewInterface(comptrollerAddress);
        (bool isListed, uint256 collateralFactorMantissa) = comptroller.markets(address(seToken));

        address underlyingAssetAddress = seToken.underlying();
        uint256 underlyingDecimals = IERC20Metadata(underlyingAssetAddress).decimals();

        return
            SeTokenMetadata({
                seToken: address(seToken),
                exchangeRateCurrent: exchangeRateCurrent,
                supplyRatePerBlock: seToken.supplyRatePerBlock(),
                borrowRatePerBlock: seToken.borrowRatePerBlock(),
                reserveFactorMantissa: seToken.reserveFactorMantissa(),
                supplyCaps: comptroller.supplyCaps(address(seToken)),
                borrowCaps: comptroller.borrowCaps(address(seToken)),
                totalBorrows: seToken.totalBorrows(),
                totalReserves: seToken.totalReserves(),
                totalSupply: seToken.totalSupply(),
                totalCash: seToken.getCash(),
                isListed: isListed,
                collateralFactorMantissa: collateralFactorMantissa,
                underlyingAssetAddress: underlyingAssetAddress,
                seTokenDecimals: seToken.decimals(),
                underlyingDecimals: underlyingDecimals
            });
    }

    /**
     * @notice Returns the metadata of all SeTokens
     * @param seTokens The list of seToken addresses
     * @return An array of SeTokenMetadata structs
     */
    function seTokenMetadataAll(SeToken[] memory seTokens) public view returns (SeTokenMetadata[] memory) {
        uint256 seTokenCount = seTokens.length;
        SeTokenMetadata[] memory res = new SeTokenMetadata[](seTokenCount);
        for (uint256 i; i < seTokenCount; ++i) {
            res[i] = seTokenMetadata(seTokens[i]);
        }
        return res;
    }

    /**
     * @notice Returns the price data for the underlying asset of the specified seToken
     * @param seToken seToken address
     * @return The price data for each asset
     */
    function seTokenUnderlyingPrice(SeToken seToken) public view returns (SeTokenUnderlyingPrice memory) {
        ComptrollerViewInterface comptroller = ComptrollerViewInterface(address(seToken.comptroller()));
        ResilientOracleInterface priceOracle = comptroller.oracle();

        return
            SeTokenUnderlyingPrice({
                seToken: address(seToken),
                underlyingPrice: priceOracle.getUnderlyingPrice(address(seToken))
            });
    }

    function _calculateNotDistributedAwards(
        address account,
        SeToken[] memory markets,
        RewardsDistributor rewardsDistributor
    ) internal view returns (PendingReward[] memory) {
        PendingReward[] memory pendingRewards = new PendingReward[](markets.length);
        for (uint256 i; i < markets.length; ++i) {
            // Market borrow and supply state we will modify update in-memory, in order to not modify storage
            RewardTokenState memory borrowState;
            (borrowState.index, borrowState.block, borrowState.lastRewardingBlock) = rewardsDistributor
                .rewardTokenBorrowState(address(markets[i]));
            RewardTokenState memory supplyState;
            (supplyState.index, supplyState.block, supplyState.lastRewardingBlock) = rewardsDistributor
                .rewardTokenSupplyState(address(markets[i]));
            Exp memory marketBorrowIndex = Exp({ mantissa: markets[i].borrowIndex() });

            // Update market supply and borrow index in-memory
            updateMarketBorrowIndex(address(markets[i]), rewardsDistributor, borrowState, marketBorrowIndex);
            updateMarketSupplyIndex(address(markets[i]), rewardsDistributor, supplyState);

            // Calculate pending rewards
            uint256 borrowReward = calculateBorrowerReward(
                address(markets[i]),
                rewardsDistributor,
                account,
                borrowState,
                marketBorrowIndex
            );
            uint256 supplyReward = calculateSupplierReward(
                address(markets[i]),
                rewardsDistributor,
                account,
                supplyState
            );

            PendingReward memory pendingReward;
            pendingReward.seTokenAddress = address(markets[i]);
            pendingReward.amount = borrowReward + supplyReward;
            pendingRewards[i] = pendingReward;
        }
        return pendingRewards;
    }

    function updateMarketBorrowIndex(
        address seToken,
        RewardsDistributor rewardsDistributor,
        RewardTokenState memory borrowState,
        Exp memory marketBorrowIndex
    ) internal view {
        uint256 borrowSpeed = rewardsDistributor.rewardTokenBorrowSpeeds(seToken);
        uint256 blockNumber = block.number;

        if (borrowState.lastRewardingBlock > 0 && blockNumber > borrowState.lastRewardingBlock) {
            blockNumber = borrowState.lastRewardingBlock;
        }

        uint256 deltaBlocks = sub_(blockNumber, uint256(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            // Remove the total earned interest rate since the opening of the market from total borrows
            uint256 borrowAmount = div_(SeToken(seToken).totalBorrows(), marketBorrowIndex);
            uint256 tokensAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(tokensAccrued, borrowAmount) : Double({ mantissa: 0 });
            Double memory index = add_(Double({ mantissa: borrowState.index }), ratio);
            borrowState.index = safe224(index.mantissa, "new index overflows");
            borrowState.block = safe32(blockNumber, "block number overflows");
        } else if (deltaBlocks > 0) {
            borrowState.block = safe32(blockNumber, "block number overflows");
        }
    }

    function updateMarketSupplyIndex(
        address seToken,
        RewardsDistributor rewardsDistributor,
        RewardTokenState memory supplyState
    ) internal view {
        uint256 supplySpeed = rewardsDistributor.rewardTokenSupplySpeeds(seToken);
        uint256 blockNumber = block.number;

        if (supplyState.lastRewardingBlock > 0 && blockNumber > supplyState.lastRewardingBlock) {
            blockNumber = supplyState.lastRewardingBlock;
        }

        uint256 deltaBlocks = sub_(blockNumber, uint256(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint256 supplyTokens = SeToken(seToken).totalSupply();
            uint256 tokensAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(tokensAccrued, supplyTokens) : Double({ mantissa: 0 });
            Double memory index = add_(Double({ mantissa: supplyState.index }), ratio);
            supplyState.index = safe224(index.mantissa, "new index overflows");
            supplyState.block = safe32(blockNumber, "block number overflows");
        } else if (deltaBlocks > 0) {
            supplyState.block = safe32(blockNumber, "block number overflows");
        }
    }

    function calculateBorrowerReward(
        address seToken,
        RewardsDistributor rewardsDistributor,
        address borrower,
        RewardTokenState memory borrowState,
        Exp memory marketBorrowIndex
    ) internal view returns (uint256) {
        Double memory borrowIndex = Double({ mantissa: borrowState.index });
        Double memory borrowerIndex = Double({
            mantissa: rewardsDistributor.rewardTokenBorrowerIndex(seToken, borrower)
        });
        if (borrowerIndex.mantissa == 0 && borrowIndex.mantissa >= rewardsDistributor.INITIAL_INDEX()) {
            // Covers the case where users borrowed tokens before the market's borrow state index was set
            borrowerIndex.mantissa = rewardsDistributor.INITIAL_INDEX();
        }
        Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
        uint256 borrowerAmount = div_(SeToken(seToken).borrowBalanceStored(borrower), marketBorrowIndex);
        uint256 borrowerDelta = mul_(borrowerAmount, deltaIndex);
        return borrowerDelta;
    }

    function calculateSupplierReward(
        address seToken,
        RewardsDistributor rewardsDistributor,
        address supplier,
        RewardTokenState memory supplyState
    ) internal view returns (uint256) {
        Double memory supplyIndex = Double({ mantissa: supplyState.index });
        Double memory supplierIndex = Double({
            mantissa: rewardsDistributor.rewardTokenSupplierIndex(seToken, supplier)
        });
        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa >= rewardsDistributor.INITIAL_INDEX()) {
            // Covers the case where users supplied tokens before the market's supply state index was set
            supplierIndex.mantissa = rewardsDistributor.INITIAL_INDEX();
        }
        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        uint256 supplierTokens = SeToken(seToken).balanceOf(supplier);
        uint256 supplierDelta = mul_(supplierTokens, deltaIndex);
        return supplierDelta;
    }
}
