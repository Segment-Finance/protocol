pragma solidity ^0.8.20;


import "../Tokens/SeTokens/SeBep20.sol";
import "../Tokens/SeTokens/SeToken.sol";
import "../../../oracle/contracts/PriceOracle.sol";
import "../Tokens/EIP20Interface.sol";
import "../Governance/GovernorAlpha.sol";
import "../Tokens/SEF/SEF.sol";
import "../Comptroller/ComptrollerInterface.sol";
import "../Utils/SafeMath.sol";

contract SegmentLens is ExponentialNoError {
    using SafeMath for uint;

    /// @notice Blocks Per Day
    uint public constant BLOCKS_PER_DAY = 28800;

    struct SegmentMarketState {
        uint224 index;
        uint32 block;
    }

    struct SeTokenMetadata {
        address seToken;
        uint exchangeRateCurrent;
        uint supplyRatePerBlock;
        uint borrowRatePerBlock;
        uint reserveFactorMantissa;
        uint totalBorrows;
        uint totalReserves;
        uint totalSupply;
        uint totalCash;
        bool isListed;
        uint collateralFactorMantissa;
        address underlyingAssetAddress;
        uint seTokenDecimals;
        uint underlyingDecimals;
        uint segmentSupplySpeed;
        uint segmentBorrowSpeed;
        uint dailySupplySef;
        uint dailyBorrowSef;
    }

    struct SeTokenBalances {
        address seToken;
        uint balanceOf;
        uint borrowBalanceCurrent;
        uint balanceOfUnderlying;
        uint tokenBalance;
        uint tokenAllowance;
    }

    struct SeTokenUnderlyingPrice {
        address seToken;
        uint underlyingPrice;
    }

    struct AccountLimits {
        SeToken[] markets;
        uint liquidity;
        uint shortfall;
    }

    struct GovReceipt {
        uint proposalId;
        bool hasVoted;
        bool support;
        uint96 votes;
    }

    struct GovProposal {
        uint proposalId;
        address proposer;
        uint eta;
        address[] targets;
        uint[] values;
        string[] signatures;
        bytes[] calldatas;
        uint startBlock;
        uint endBlock;
        uint forVotes;
        uint againstVotes;
        bool canceled;
        bool executed;
    }

    struct SEFBalanceMetadata {
        uint balance;
        uint votes;
        address delegate;
    }

    struct SEFBalanceMetadataExt {
        uint balance;
        uint votes;
        address delegate;
        uint allocated;
    }

    struct SegmentVotes {
        uint blockNumber;
        uint votes;
    }

    struct ClaimSegmentLocalVariables {
        uint totalRewards;
        uint224 borrowIndex;
        uint32 borrowBlock;
        uint224 supplyIndex;
        uint32 supplyBlock;
    }

    /**
     * @dev Struct for Pending Rewards for per market
     */
    struct PendingReward {
        address seTokenAddress;
        uint256 amount;
    }

    /**
     * @dev Struct for Reward of a single reward token.
     */
    struct RewardSummary {
        address distributorAddress;
        address rewardTokenAddress;
        uint256 totalRewards;
        PendingReward[] pendingRewards;
    }

    /**
     * @notice Query the metadata of a seToken by its address
     * @param seToken The address of the seToken to fetch SeTokenMetadata
     * @return SeTokenMetadata struct with seToken supply and borrow information.
     */
    function seTokenMetadata(SeToken seToken) public returns (SeTokenMetadata memory) {
        uint exchangeRateCurrent = seToken.exchangeRateCurrent();
        address comptrollerAddress = address(seToken.comptroller());
        ComptrollerInterface comptroller = ComptrollerInterface(comptrollerAddress);
        (bool isListed, uint collateralFactorMantissa) = comptroller.markets(address(seToken));
        address underlyingAssetAddress;
        uint underlyingDecimals;

        if (compareStrings(seToken.symbol(), "seBNB")) {
            underlyingAssetAddress = address(0);
            underlyingDecimals = 18;
        } else {
            SeBep20 seBep20 = SeBep20(address(seToken));
            underlyingAssetAddress = seBep20.underlying();
            underlyingDecimals = EIP20Interface(seBep20.underlying()).decimals();
        }

        uint segmentSupplySpeedPerBlock = comptroller.segmentSupplySpeeds(address(seToken));
        uint segmentBorrowSpeedPerBlock = comptroller.segmentBorrowSpeeds(address(seToken));

        return
            SeTokenMetadata({
                seToken: address(seToken),
                exchangeRateCurrent: exchangeRateCurrent,
                supplyRatePerBlock: seToken.supplyRatePerBlock(),
                borrowRatePerBlock: seToken.borrowRatePerBlock(),
                reserveFactorMantissa: seToken.reserveFactorMantissa(),
                totalBorrows: seToken.totalBorrows(),
                totalReserves: seToken.totalReserves(),
                totalSupply: seToken.totalSupply(),
                totalCash: seToken.getCash(),
                isListed: isListed,
                collateralFactorMantissa: collateralFactorMantissa,
                underlyingAssetAddress: underlyingAssetAddress,
                seTokenDecimals: seToken.decimals(),
                underlyingDecimals: underlyingDecimals,
                segmentSupplySpeed: segmentSupplySpeedPerBlock,
                segmentBorrowSpeed: segmentBorrowSpeedPerBlock,
                dailySupplySef: segmentSupplySpeedPerBlock.mul(BLOCKS_PER_DAY),
                dailyBorrowSef: segmentBorrowSpeedPerBlock.mul(BLOCKS_PER_DAY)
            });
    }

    /**
     * @notice Get SeTokenMetadata for an array of seToken addresses
     * @param seTokens Array of seToken addresses to fetch SeTokenMetadata
     * @return Array of structs with seToken supply and borrow information.
     */
    function seTokenMetadataAll(SeToken[] calldata seTokens) external returns (SeTokenMetadata[] memory) {
        uint seTokenCount = seTokens.length;
        SeTokenMetadata[] memory res = new SeTokenMetadata[](seTokenCount);
        for (uint i = 0; i < seTokenCount; i++) {
            res[i] = seTokenMetadata(seTokens[i]);
        }
        return res;
    }

    /**
     * @notice Get amount of SEF distributed daily to an account
     * @param account Address of account to fetch the daily SEF distribution
     * @param comptrollerAddress Address of the comptroller proxy
     * @return Amount of SEF distributed daily to an account
     */
    function getDailySEF(address payable account, address comptrollerAddress) external returns (uint) {
        ComptrollerInterface comptrollerInstance = ComptrollerInterface(comptrollerAddress);
        SeToken[] memory seTokens = comptrollerInstance.getAllMarkets();
        uint dailySefPerAccount = 0;

        for (uint i = 0; i < seTokens.length; i++) {
            SeToken seToken = seTokens[i];
            if (!compareStrings(seToken.symbol(), "seUST") && !compareStrings(seToken.symbol(), "seLUNA")) {
                SeTokenMetadata memory metaDataItem = seTokenMetadata(seToken);

                //get balanceOfUnderlying and borrowBalanceCurrent from seTokenBalance
                SeTokenBalances memory seTokenBalanceInfo = seTokenBalances(seToken, account);

                SeTokenUnderlyingPrice memory underlyingPriceResponse = seTokenUnderlyingPrice(seToken);
                uint underlyingPrice = underlyingPriceResponse.underlyingPrice;
                Exp memory underlyingPriceMantissa = Exp({ mantissa: underlyingPrice });

                //get dailySefSupplyMarket
                uint dailySefSupplyMarket = 0;
                uint supplyInUsd = mul_ScalarTruncate(underlyingPriceMantissa, seTokenBalanceInfo.balanceOfUnderlying);
                uint marketTotalSupply = (metaDataItem.totalSupply.mul(metaDataItem.exchangeRateCurrent)).div(1e18);
                uint marketTotalSupplyInUsd = mul_ScalarTruncate(underlyingPriceMantissa, marketTotalSupply);

                if (marketTotalSupplyInUsd > 0) {
                    dailySefSupplyMarket = (metaDataItem.dailySupplySef.mul(supplyInUsd)).div(marketTotalSupplyInUsd);
                }

                //get dailySefBorrowMarket
                uint dailySefBorrowMarket = 0;
                uint borrowsInUsd = mul_ScalarTruncate(underlyingPriceMantissa, seTokenBalanceInfo.borrowBalanceCurrent);
                uint marketTotalBorrowsInUsd = mul_ScalarTruncate(underlyingPriceMantissa, metaDataItem.totalBorrows);

                if (marketTotalBorrowsInUsd > 0) {
                    dailySefBorrowMarket = (metaDataItem.dailyBorrowSef.mul(borrowsInUsd)).div(marketTotalBorrowsInUsd);
                }

                dailySefPerAccount += dailySefSupplyMarket + dailySefBorrowMarket;
            }
        }

        return dailySefPerAccount;
    }

    /**
     * @notice Get the current seToken balance (outstanding borrows) for an account
     * @param seToken Address of the token to check the balance of
     * @param account Account address to fetch the balance of
     * @return SeTokenBalances with token balance information
     */
    function seTokenBalances(SeToken seToken, address payable account) public returns (SeTokenBalances memory) {
        uint balanceOf = seToken.balanceOf(account);
        uint borrowBalanceCurrent = seToken.borrowBalanceCurrent(account);
        uint balanceOfUnderlying = seToken.balanceOfUnderlying(account);
        uint tokenBalance;
        uint tokenAllowance;

        if (compareStrings(seToken.symbol(), "seBNB")) {
            tokenBalance = account.balance;
            tokenAllowance = account.balance;
        } else {
            SeBep20 seBep20 = SeBep20(address(seToken));
            EIP20Interface underlying = EIP20Interface(seBep20.underlying());
            tokenBalance = underlying.balanceOf(account);
            tokenAllowance = underlying.allowance(account, address(seToken));
        }

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
     * @notice Get the current seToken balances (outstanding borrows) for all seTokens on an account
     * @param seTokens Addresses of the tokens to check the balance of
     * @param account Account address to fetch the balance of
     * @return SeTokenBalances Array with token balance information
     */
    function seTokenBalancesAll(
        SeToken[] calldata seTokens,
        address payable account
    ) external returns (SeTokenBalances[] memory) {
        uint seTokenCount = seTokens.length;
        SeTokenBalances[] memory res = new SeTokenBalances[](seTokenCount);
        for (uint i = 0; i < seTokenCount; i++) {
            res[i] = seTokenBalances(seTokens[i], account);
        }
        return res;
    }

    /**
     * @notice Get the price for the underlying asset of a seToken
     * @param seToken address of the seToken
     * @return response struct with underlyingPrice info of seToken
     */
    function seTokenUnderlyingPrice(SeToken seToken) public view returns (SeTokenUnderlyingPrice memory) {
        ComptrollerInterface comptroller = ComptrollerInterface(address(seToken.comptroller()));
        PriceOracle priceOracle = comptroller.oracle();

        return
            SeTokenUnderlyingPrice({ seToken: address(seToken), underlyingPrice: priceOracle.getUnderlyingPrice(seToken) });
    }

    /**
     * @notice Query the underlyingPrice of an array of seTokens
     * @param seTokens Array of seToken addresses
     * @return array of response structs with underlying price information of seTokens
     */
    function seTokenUnderlyingPriceAll(
        SeToken[] calldata seTokens
    ) external view returns (SeTokenUnderlyingPrice[] memory) {
        uint seTokenCount = seTokens.length;
        SeTokenUnderlyingPrice[] memory res = new SeTokenUnderlyingPrice[](seTokenCount);
        for (uint i = 0; i < seTokenCount; i++) {
            res[i] = seTokenUnderlyingPrice(seTokens[i]);
        }
        return res;
    }

    /**
     * @notice Query the account liquidity and shortfall of an account
     * @param comptroller Address of comptroller proxy
     * @param account Address of the account to query
     * @return Struct with markets user has entered, liquidity, and shortfall of the account
     */
    function getAccountLimits(
        ComptrollerInterface comptroller,
        address account
    ) public view returns (AccountLimits memory) {
        (uint errorCode, uint liquidity, uint shortfall) = comptroller.getAccountLiquidity(account);
        require(errorCode == 0, "account liquidity error");

        return AccountLimits({ markets: comptroller.getAssetsIn(account), liquidity: liquidity, shortfall: shortfall });
    }

    /**
     * @notice Query the voting information of an account for a list of governance proposals
     * @param governor Governor address
     * @param voter Voter address
     * @param proposalIds Array of proposal ids
     * @return Array of governor receipts
     */
    function getGovReceipts(
        GovernorAlpha governor,
        address voter,
        uint[] memory proposalIds
    ) public view returns (GovReceipt[] memory) {
        uint proposalCount = proposalIds.length;
        GovReceipt[] memory res = new GovReceipt[](proposalCount);
        for (uint i = 0; i < proposalCount; i++) {
            GovernorAlpha.Receipt memory receipt = governor.getReceipt(proposalIds[i], voter);
            res[i] = GovReceipt({
                proposalId: proposalIds[i],
                hasVoted: receipt.hasVoted,
                support: receipt.support,
                votes: receipt.votes
            });
        }
        return res;
    }

    /**
     * @dev Given a GovProposal struct, fetches and sets proposal data
     * @param res GovernProposal struct
     * @param governor Governor address
     * @param proposalId Id of a proposal
     */
    function setProposal(GovProposal memory res, GovernorAlpha governor, uint proposalId) internal view {
        (
            ,
            address proposer,
            uint eta,
            uint startBlock,
            uint endBlock,
            uint forVotes,
            uint againstVotes,
            bool canceled,
            bool executed
        ) = governor.proposals(proposalId);
        res.proposalId = proposalId;
        res.proposer = proposer;
        res.eta = eta;
        res.startBlock = startBlock;
        res.endBlock = endBlock;
        res.forVotes = forVotes;
        res.againstVotes = againstVotes;
        res.canceled = canceled;
        res.executed = executed;
    }

    /**
     * @notice Query the details of a list of governance proposals
     * @param governor Address of governor contract
     * @param proposalIds Array of proposal Ids
     * @return GovProposal structs for provided proposal Ids
     */
    function getGovProposals(
        GovernorAlpha governor,
        uint[] calldata proposalIds
    ) external view returns (GovProposal[] memory) {
        GovProposal[] memory res = new GovProposal[](proposalIds.length);
        for (uint i = 0; i < proposalIds.length; i++) {
            (
                address[] memory targets,
                uint[] memory values,
                string[] memory signatures,
                bytes[] memory calldatas
            ) = governor.getActions(proposalIds[i]);
            res[i] = GovProposal({
                proposalId: 0,
                proposer: address(0),
                eta: 0,
                targets: targets,
                values: values,
                signatures: signatures,
                calldatas: calldatas,
                startBlock: 0,
                endBlock: 0,
                forVotes: 0,
                againstVotes: 0,
                canceled: false,
                executed: false
            });
            setProposal(res[i], governor, proposalIds[i]);
        }
        return res;
    }

    /**
     * @notice Query the SEFBalance info of an account
     * @param sef SEF contract address
     * @param account Account address
     * @return Struct with SEF balance and voter details
     */
    function getSEFBalanceMetadata(SEF sef, address account) external view returns (SEFBalanceMetadata memory) {
        return
            SEFBalanceMetadata({
                balance: sef.balanceOf(account),
                votes: uint256(sef.getCurrentVotes(account)),
                delegate: sef.delegates(account)
            });
    }

    /**
     * @notice Query the SEFBalance extended info of an account
     * @param sef SEF contract address
     * @param comptroller Comptroller proxy contract address
     * @param account Account address
     * @return Struct with SEF balance and voter details and SEF allocation
     */
    function getSEFBalanceMetadataExt(
        SEF sef,
        ComptrollerInterface comptroller,
        address account
    ) external returns (SEFBalanceMetadataExt memory) {
        uint balance = sef.balanceOf(account);
        comptroller.claimSegment(account);
        uint newBalance = sef.balanceOf(account);
        uint accrued = comptroller.segmentAccrued(account);
        uint total = add_(accrued, newBalance, "sum sef total");
        uint allocated = sub_(total, balance, "sub allocated");

        return
            SEFBalanceMetadataExt({
                balance: balance,
                votes: uint256(sef.getCurrentVotes(account)),
                delegate: sef.delegates(account),
                allocated: allocated
            });
    }

    /**
     * @notice Query the voting power for an account at a specific list of block numbers
     * @param sef SEF contract address
     * @param account Address of the account
     * @param blockNumbers Array of blocks to query
     * @return Array of SegmentVotes structs with block number and vote count
     */
    function getSegmentVotes(
        SEF sef,
        address account,
        uint32[] calldata blockNumbers
    ) external view returns (SegmentVotes[] memory) {
        SegmentVotes[] memory res = new SegmentVotes[](blockNumbers.length);
        for (uint i = 0; i < blockNumbers.length; i++) {
            res[i] = SegmentVotes({
                blockNumber: uint256(blockNumbers[i]),
                votes: uint256(sef.getPriorVotes(account, blockNumbers[i]))
            });
        }
        return res;
    }

    /**
     * @dev Queries the current supply to calculate rewards for an account
     * @param supplyState SegmentMarketState struct
     * @param seToken Address of a seToken
     * @param comptroller Address of the comptroller proxy
     */
    function updateSegmentSupplyIndex(
        SegmentMarketState memory supplyState,
        address seToken,
        ComptrollerInterface comptroller
    ) internal view {
        uint supplySpeed = comptroller.segmentSupplySpeeds(seToken);
        uint blockNumber = block.number;
        uint deltaBlocks = sub_(blockNumber, uint(supplyState.block));
        if (deltaBlocks > 0 && supplySpeed > 0) {
            uint supplyTokens = SeToken(seToken).totalSupply();
            uint segmentAccrued = mul_(deltaBlocks, supplySpeed);
            Double memory ratio = supplyTokens > 0 ? fraction(segmentAccrued, supplyTokens) : Double({ mantissa: 0 });
            Double memory index = add_(Double({ mantissa: supplyState.index }), ratio);
            supplyState.index = safe224(index.mantissa, "new index overflows");
            supplyState.block = safe32(blockNumber, "block number overflows");
        } else if (deltaBlocks > 0) {
            supplyState.block = safe32(blockNumber, "block number overflows");
        }
    }

    /**
     * @dev Queries the current borrow to calculate rewards for an account
     * @param borrowState SegmentMarketState struct
     * @param seToken Address of a seToken
     * @param comptroller Address of the comptroller proxy
     */
    function updateSegmentBorrowIndex(
        SegmentMarketState memory borrowState,
        address seToken,
        Exp memory marketBorrowIndex,
        ComptrollerInterface comptroller
    ) internal view {
        uint borrowSpeed = comptroller.segmentBorrowSpeeds(seToken);
        uint blockNumber = block.number;
        uint deltaBlocks = sub_(blockNumber, uint(borrowState.block));
        if (deltaBlocks > 0 && borrowSpeed > 0) {
            uint borrowAmount = div_(SeToken(seToken).totalBorrows(), marketBorrowIndex);
            uint segmentAccrued = mul_(deltaBlocks, borrowSpeed);
            Double memory ratio = borrowAmount > 0 ? fraction(segmentAccrued, borrowAmount) : Double({ mantissa: 0 });
            Double memory index = add_(Double({ mantissa: borrowState.index }), ratio);
            borrowState.index = safe224(index.mantissa, "new index overflows");
            borrowState.block = safe32(blockNumber, "block number overflows");
        } else if (deltaBlocks > 0) {
            borrowState.block = safe32(blockNumber, "block number overflows");
        }
    }

    /**
     * @dev Calculate available rewards for an account's supply
     * @param supplyState SegmentMarketState struct
     * @param seToken Address of a seToken
     * @param supplier Address of the account supplying
     * @param comptroller Address of the comptroller proxy
     * @return Undistributed earned SEF from supplies
     */
    function distributeSupplierSegment(
        SegmentMarketState memory supplyState,
        address seToken,
        address supplier,
        ComptrollerInterface comptroller
    ) internal view returns (uint) {
        Double memory supplyIndex = Double({ mantissa: supplyState.index });
        Double memory supplierIndex = Double({ mantissa: comptroller.segmentSupplierIndex(seToken, supplier) });
        if (supplierIndex.mantissa == 0 && supplyIndex.mantissa > 0) {
            supplierIndex.mantissa = comptroller.segmentInitialIndex();
        }

        Double memory deltaIndex = sub_(supplyIndex, supplierIndex);
        uint supplierTokens = SeToken(seToken).balanceOf(supplier);
        uint supplierDelta = mul_(supplierTokens, deltaIndex);
        return supplierDelta;
    }

    /**
     * @dev Calculate available rewards for an account's borrows
     * @param borrowState SegmentMarketState struct
     * @param seToken Address of a seToken
     * @param borrower Address of the account borrowing
     * @param marketBorrowIndex seToken Borrow index
     * @param comptroller Address of the comptroller proxy
     * @return Undistributed earned SEF from borrows
     */
    function distributeBorrowerSegment(
        SegmentMarketState memory borrowState,
        address seToken,
        address borrower,
        Exp memory marketBorrowIndex,
        ComptrollerInterface comptroller
    ) internal view returns (uint) {
        Double memory borrowIndex = Double({ mantissa: borrowState.index });
        Double memory borrowerIndex = Double({ mantissa: comptroller.segmentBorrowerIndex(seToken, borrower) });
        if (borrowerIndex.mantissa > 0) {
            Double memory deltaIndex = sub_(borrowIndex, borrowerIndex);
            uint borrowerAmount = div_(SeToken(seToken).borrowBalanceStored(borrower), marketBorrowIndex);
            uint borrowerDelta = mul_(borrowerAmount, deltaIndex);
            return borrowerDelta;
        }
        return 0;
    }

    /**
     * @notice Calculate the total SEF tokens pending and accrued by a user account
     * @param holder Account to query pending SEF
     * @param comptroller Address of the comptroller
     * @return Reward object contraining the totalRewards and pending rewards for each market
     */
    function pendingRewards(
        address holder,
        ComptrollerInterface comptroller
    ) external view returns (RewardSummary memory) {
        SeToken[] memory seTokens = comptroller.getAllMarkets();
        ClaimSegmentLocalVariables memory vars;
        RewardSummary memory rewardSummary;
        rewardSummary.distributorAddress = address(comptroller);
        rewardSummary.rewardTokenAddress = comptroller.getSEFAddress();
        rewardSummary.totalRewards = comptroller.segmentAccrued(holder);
        rewardSummary.pendingRewards = new PendingReward[](seTokens.length);
        for (uint i; i < seTokens.length; ++i) {
            (vars.borrowIndex, vars.borrowBlock) = comptroller.segmentBorrowState(address(seTokens[i]));
            SegmentMarketState memory borrowState = SegmentMarketState({
                index: vars.borrowIndex,
                block: vars.borrowBlock
            });

            (vars.supplyIndex, vars.supplyBlock) = comptroller.segmentSupplyState(address(seTokens[i]));
            SegmentMarketState memory supplyState = SegmentMarketState({
                index: vars.supplyIndex,
                block: vars.supplyBlock
            });

            Exp memory borrowIndex = Exp({ mantissa: seTokens[i].borrowIndex() });

            PendingReward memory marketReward;
            marketReward.seTokenAddress = address(seTokens[i]);

            updateSegmentBorrowIndex(borrowState, address(seTokens[i]), borrowIndex, comptroller);
            uint256 borrowReward = distributeBorrowerSegment(
                borrowState,
                address(seTokens[i]),
                holder,
                borrowIndex,
                comptroller
            );

            updateSegmentSupplyIndex(supplyState, address(seTokens[i]), comptroller);
            uint256 supplyReward = distributeSupplierSegment(supplyState, address(seTokens[i]), holder, comptroller);

            marketReward.amount = add_(borrowReward, supplyReward);
            rewardSummary.pendingRewards[i] = marketReward;
        }
        return rewardSummary;
    }

    // utilities
    /**
     * @notice Compares if two strings are equal
     * @param a First string to compare
     * @param b Second string to compare
     * @return Boolean depending on if the strings are equal
     */
    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
