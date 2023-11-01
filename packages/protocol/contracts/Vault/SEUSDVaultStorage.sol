pragma solidity ^0.8.20;
import "../Utils/SafeMath.sol";
import "../Utils/IBEP20.sol";

contract SEUSDVaultAdminStorage {
    /**
     * @notice Administrator for this contract
     */
    address public admin;

    /**
     * @notice Pending administrator for this contract
     */
    address public pendingAdmin;

    /**
     * @notice Active brains of SEUSD Vault
     */
    address public seusdVaultImplementation;

    /**
     * @notice Pending brains of SEUSD Vault
     */
    address public pendingSEUSDVaultImplementation;
}

contract SEUSDVaultStorage is SEUSDVaultAdminStorage {
    /// @notice The SEF TOKEN!
    IBEP20 public sef;

    /// @notice The SEUSD TOKEN!
    IBEP20 public seusd;

    /// @notice Guard variable for re-entrancy checks
    bool internal _notEntered;

    /// @notice SEF balance of vault
    uint256 public sefBalance;

    /// @notice Accumulated SEF per share
    uint256 public accSEFPerShare;

    //// pending rewards awaiting anyone to update
    uint256 public pendingRewards;

    /// @notice Info of each user.
    struct UserInfo {
        uint256 amount;
        uint256 rewardDebt;
    }

    // Info of each user that stakes tokens.
    mapping(address => UserInfo) public userInfo;

    /// @notice pause indicator for Vault
    bool public vaultPaused;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;
}
