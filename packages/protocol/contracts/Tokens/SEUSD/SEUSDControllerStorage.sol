pragma solidity ^0.8.20;

import "../../Comptroller/ComptrollerInterface.sol";

contract SEUSDUnitrollerAdminStorage {
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
    address public seusdControllerImplementation;

    /**
     * @notice Pending brains of Unitroller
     */
    address public pendingSEUSDControllerImplementation;
}

contract SEUSDControllerStorageG1 is SEUSDUnitrollerAdminStorage {
    ComptrollerInterface public comptroller;

    struct SegmentSEUSDState {
        /// @notice The last updated segmentSEUSDMintIndex
        uint224 index;
        /// @notice The block number the index was last updated at
        uint32 block;
    }

    /// @notice The Segment SEUSD state
    SegmentSEUSDState public segmentSEUSDState;

    /// @notice The Segment SEUSD state initialized
    bool public isSegmentSEUSDInitialized;

    /// @notice The Segment SEUSD minter index as of the last time they accrued SEF
    mapping(address => uint) public segmentSEUSDMinterIndex;
}

contract SEUSDControllerStorageG2 is SEUSDControllerStorageG1 {
    /// @notice Treasury Guardian address
    address public treasuryGuardian;

    /// @notice Treasury address
    address public treasuryAddress;

    /// @notice Fee percent of accrued interest with decimal 18
    uint256 public treasuryPercent;

    /// @notice Guard variable for re-entrancy checks
    bool internal _notEntered;

    /// @notice The base rate for stability fee
    uint public baseRateMantissa;

    /// @notice The float rate for stability fee
    uint public floatRateMantissa;

    /// @notice The address for SEUSD interest receiver
    address public receiver;

    /// @notice Accumulator of the total earned interest rate since the opening of the market. For example: 0.6 (60%)
    uint public seusdMintIndex;

    /// @notice Block number that interest was last accrued at
    uint internal accrualBlockNumber;

    /// @notice Global seusdMintIndex as of the most recent balance-changing action for user
    mapping(address => uint) internal seusdMinterInterestIndex;

    /// @notice Tracks the amount of mintedSEUSD of a user that represents the accrued interest
    mapping(address => uint) public pastSEUSDInterest;

    /// @notice SEUSD mint cap
    uint public mintCap;

    /// @notice Access control manager address
    address public accessControl;
}
