pragma solidity ^0.8.20;
import "../Utils/SafeMath.sol";
import "../Utils/IBEP20.sol";

contract SRTVaultAdminStorage {
    /**
     * @notice Administrator for this contract
     */
    address public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address public pendingAdmin;

    /**
     * @notice Active brains of SRT Vault
     */
    address public implementation;

    /**
     * @notice Pending brains of SEUSD Vault
     */
    address public pendingImplementation;
}

contract SRTVaultStorage is SRTVaultAdminStorage {
    /// @notice Guard variable for re-entrancy checks
    bool public _notEntered;

    /// @notice pause indicator for Vault
    bool public vaultPaused;

    /// @notice The SRT TOKEN!
    IBEP20 public srt;

    /// @notice interestRate for accrual - per Block
    uint256 public interestRatePerBlock;

    /// @notice Info of each user.
    struct UserInfo {
        address userAddress;
        uint256 accrualStartBlockNumber;
        uint256 totalPrincipalAmount;
        uint256 lastWithdrawnBlockNumber;
    }

    // Info of each user that stakes tokens.
    mapping(address => UserInfo) public userInfo;

    /// @notice block number after which no interest will be accrued
    uint256 public lastAccruingBlock;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}
