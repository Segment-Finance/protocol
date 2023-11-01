// SPDX-License-Identifier: BSD-3-Clause

pragma solidity ^0.8.20;

import { SeToken } from "../Tokens/SeTokens/SeToken.sol";
import { PriceOracle } from "../../../oracle/contracts/PriceOracle.sol";
import { SEUSDControllerInterface } from "../Tokens/SEUSD/SEUSDControllerInterface.sol";
import { ComptrollerLensInterface } from "./ComptrollerLensInterface.sol";

contract UnitrollerAdminStorage {
    /**
     * @notice Administrator for this contract
     */
    address public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address public pendingAdmin;

    /**
     * @notice Active brains of Unitroller
     */
    address public comptrollerImplementation;

    /**
     * @notice Pending brains of Unitroller
     */
    address public pendingComptrollerImplementation;
}

contract ComptrollerV1Storage is UnitrollerAdminStorage {
    /**
     * @notice Oracle which gives the price of any given asset
     */
    PriceOracle public oracle;

    /**
     * @notice Multiplier used to calculate the maximum repayAmount when liquidating a borrow
     */
    uint256 public closeFactorMantissa;

    /**
     * @notice Multiplier representing the discount on collateral that a liquidator receives
     */
    uint256 public liquidationIncentiveMantissa;

    /**
     * @notice Max number of assets a single account can participate in (borrow or use as collateral)
     */
    uint256 public maxAssets;

    /**
     * @notice Per-account mapping of "assets you are in", capped by maxAssets
     */
    mapping(address => SeToken[]) public accountAssets;

    struct Market {
        /// @notice Whether or not this market is listed
        bool isListed;
        /**
         * @notice Multiplier representing the most one can borrow against their collateral in this market.
         *  For instance, 0.9 to allow borrowing 90% of collateral value.
         *  Must be between 0 and 1, and stored as a mantissa.
         */
        uint256 collateralFactorMantissa;
        /// @notice Per-market mapping of "accounts in this asset"
        mapping(address => bool) accountMembership;
        /// @notice Whether or not this market receives SEF
        bool isSegment;
    }

    /**
     * @notice Official mapping of seTokens -> Market metadata
     * @dev Used e.g. to determine if a market is supported
     */
    mapping(address => Market) public markets;

    /**
     * @notice The Pause Guardian can pause certain actions as a safety mechanism.
     */
    address public pauseGuardian;

    /// @notice Whether minting is paused (deprecated, superseded by actionPaused)
    bool private _mintGuardianPaused;
    /// @notice Whether borrowing is paused (deprecated, superseded by actionPaused)
    bool private _borrowGuardianPaused;
    /// @notice Whether borrowing is paused (deprecated, superseded by actionPaused)
    bool internal transferGuardianPaused;
    /// @notice Whether borrowing is paused (deprecated, superseded by actionPaused)
    bool internal seizeGuardianPaused;
    /// @notice Whether borrowing is paused (deprecated, superseded by actionPaused)
    mapping(address => bool) internal mintGuardianPaused;
    /// @notice Whether borrowing is paused (deprecated, superseded by actionPaused)
    mapping(address => bool) internal borrowGuardianPaused;

    struct SegmentMarketState {
        /// @notice The market's last updated segmentBorrowIndex or segmentSupplyIndex
        uint224 index;
        /// @notice The block number the index was last updated at
        uint32 block;
    }

    /// @notice A list of all markets
    SeToken[] public allMarkets;

    /// @notice The rate at which the flywheel distributes SEF, per block
    uint256 internal segmentRate;

    /// @notice The portion of segmentRate that each market currently receives
    mapping(address => uint256) internal segmentSpeeds;

    /// @notice The Segment market supply state for each market
    mapping(address => SegmentMarketState) public segmentSupplyState;

    /// @notice The Segment market borrow state for each market
    mapping(address => SegmentMarketState) public segmentBorrowState;

    /// @notice The Segment supply index for each market for each supplier as of the last time they accrued SEF
    mapping(address => mapping(address => uint256)) public segmentSupplierIndex;

    /// @notice The Segment borrow index for each market for each borrower as of the last time they accrued SEF
    mapping(address => mapping(address => uint256)) public segmentBorrowerIndex;

    /// @notice The SEF accrued but not yet transferred to each user
    mapping(address => uint256) public segmentAccrued;

    /// @notice The Address of SEUSDController
    SEUSDControllerInterface public seusdController;

    /// @notice The minted SEUSD amount to each user
    mapping(address => uint256) public mintedSEUSDs;

    /// @notice SEUSD Mint Rate as a percentage
    uint256 public seusdMintRate;

    /**
     * @notice The Pause Guardian can pause certain actions as a safety mechanism.
     */
    bool public mintSEUSDGuardianPaused;
    bool public repaySEUSDGuardianPaused;

    /**
     * @notice Pause/Unpause whole protocol actions
     */
    bool public protocolPaused;

    /// @notice The rate at which the flywheel distributes SEF to SEUSD Minters, per block (deprecated)
    uint256 private segmentSEUSDRate;
}

contract ComptrollerV2Storage is ComptrollerV1Storage {
    /// @notice The rate at which the flywheel distributes SEF to SEUSD Vault, per block
    uint256 public segmentSEUSDVaultRate;

    // address of SEUSD Vault
    address public seusdVaultAddress;

    // start block of release to SEUSD Vault
    uint256 public releaseStartBlock;

    // minimum release amount to SEUSD Vault
    uint256 public minReleaseAmount;
}

contract ComptrollerV3Storage is ComptrollerV2Storage {
    /// @notice The borrowCapGuardian can set borrowCaps to any number for any market. Lowering the borrow cap could disable borrowing on the given market.
    address public borrowCapGuardian;

    /// @notice Borrow caps enforced by borrowAllowed for each seToken address. Defaults to zero which corresponds to unlimited borrowing.
    mapping(address => uint256) public borrowCaps;
}

contract ComptrollerV4Storage is ComptrollerV3Storage {
    /// @notice Treasury Guardian address
    address public treasuryGuardian;

    /// @notice Treasury address
    address public treasuryAddress;

    /// @notice Fee percent of accrued interest with decimal 18
    uint256 public treasuryPercent;
}

contract ComptrollerV5Storage is ComptrollerV4Storage {
    /// @notice The portion of SEF that each contributor receives per block (deprecated)
    mapping(address => uint256) private segmentContributorSpeeds;

    /// @notice Last block at which a contributor's SEF rewards have been allocated (deprecated)
    mapping(address => uint256) private lastContributorBlock;
}

contract ComptrollerV6Storage is ComptrollerV5Storage {
    address public liquidatorContract;
}

contract ComptrollerV7Storage is ComptrollerV6Storage {
    ComptrollerLensInterface public comptrollerLens;
}

contract ComptrollerV8Storage is ComptrollerV7Storage {
    /// @notice Supply caps enforced by mintAllowed for each seToken address. Defaults to zero which corresponds to minting notAllowed
    mapping(address => uint256) public supplyCaps;
}

contract ComptrollerV9Storage is ComptrollerV8Storage {
    /// @notice AccessControlManager address
    address internal accessControl;

    enum Action {
        MINT,
        REDEEM,
        BORROW,
        REPAY,
        SEIZE,
        LIQUIDATE,
        TRANSFER,
        ENTER_MARKET,
        EXIT_MARKET
    }

    /// @notice True if a certain action is paused on a certain market
    mapping(address => mapping(uint256 => bool)) internal _actionPaused;
}

contract ComptrollerV10Storage is ComptrollerV9Storage {
    /// @notice The rate at which segment is distributed to the corresponding borrow market (per block)
    mapping(address => uint256) public segmentBorrowSpeeds;

    /// @notice The rate at which segment is distributed to the corresponding supply market (per block)
    mapping(address => uint256) public segmentSupplySpeeds;
}

contract ComptrollerV11Storage is ComptrollerV10Storage {
    /// @notice Whether the delegate is allowed to borrow on behalf of the borrower
    //mapping(address borrower => mapping (address delegate => bool approved)) public approvedDelegates;
    mapping(address => mapping(address => bool)) public approvedDelegates;
}

contract ComptrollerV12Storage is ComptrollerV11Storage {
    mapping(address => bool) public isForcedLiquidationEnabled;
}

contract ComptrollerV13Storage is ComptrollerV12Storage {
    struct FacetAddressAndPosition {
        address facetAddress;
        uint96 functionSelectorPosition; // position in _facetFunctionSelectors.functionSelectors array
    }

    struct FacetFunctionSelectors {
        bytes4[] functionSelectors;
        uint256 facetAddressPosition; // position of facetAddress in _facetAddresses array
    }

    mapping(bytes4 => FacetAddressAndPosition) internal _selectorToFacetAndPosition;
    // maps facet addresses to function selectors
    mapping(address => FacetFunctionSelectors) internal _facetFunctionSelectors;
    // facet addresses
    address[] internal _facetAddresses;
}

contract ComptrollerV14Storage is ComptrollerV13Storage {
    address public _sefToken;
    address public _seSefToken;
}
