pragma solidity ^0.8.20;

import "../Utils/SafeBEP20.sol";
import "../Utils/IBEP20.sol";
import "./SEUSDVaultStorage.sol";
import "./SEUSDVaultErrorReporter.sol";
import "../../../governance-contracts/contracts/Governance/AccessControlledV5.sol";

interface ISEUSDVaultProxy {
    function _acceptImplementation() external returns (uint);

    function admin() external returns (address);
}

contract SEUSDVault is SEUSDVaultStorage, AccessControlledV5 {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    /// @notice Event emitted when SEUSD deposit
    event Deposit(address indexed user, uint256 amount);

    /// @notice Event emitted when SEUSD withrawal
    event Withdraw(address indexed user, uint256 amount);

    /// @notice Event emitted when vault is paused
    event VaultPaused(address indexed admin);

    /// @notice Event emitted when vault is resumed after pause
    event VaultResumed(address indexed admin);

    constructor() public {
        admin = msg.sender;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    /*** Reentrancy Guard ***/

    /**
     * @dev Prevents a contract from calling itself, directly or indirectly.
     */
    modifier nonReentrant() {
        require(_notEntered, "re-entered");
        _notEntered = false;
        _;
        _notEntered = true; // get a gas-refund post-Istanbul
    }

    /**
     * @dev Prevents functions to execute when vault is paused.
     */
    modifier isActive() {
        require(!vaultPaused, "Vault is paused");
        _;
    }

    /**
     * @notice Pause vault
     */
    function pause() external {
        _checkAccessAllowed("pause()");
        require(!vaultPaused, "Vault is already paused");
        vaultPaused = true;
        emit VaultPaused(msg.sender);
    }

    /**
     * @notice Resume vault
     */
    function resume() external {
        _checkAccessAllowed("resume()");
        require(vaultPaused, "Vault is not paused");
        vaultPaused = false;
        emit VaultResumed(msg.sender);
    }

    /**
     * @notice Deposit SEUSD to SEUSDVault for SEF allocation
     * @param _amount The amount to deposit to vault
     */
    function deposit(uint256 _amount) external nonReentrant isActive {
        UserInfo storage user = userInfo[msg.sender];

        updateVault();

        // Transfer pending tokens to user
        updateAndPayOutPending(msg.sender);

        // Transfer in the amounts from user
        if (_amount > 0) {
            seusd.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
        }

        user.rewardDebt = user.amount.mul(accSEFPerShare).div(1e18);
        emit Deposit(msg.sender, _amount);
    }

    /**
     * @notice Withdraw SEUSD from SEUSDVault
     * @param _amount The amount to withdraw from vault
     */
    function withdraw(uint256 _amount) external nonReentrant isActive {
        _withdraw(msg.sender, _amount);
    }

    /**
     * @notice Claim SEF from SEUSDVault
     */
    function claim() external nonReentrant isActive {
        _withdraw(msg.sender, 0);
    }

    /**
     * @notice Claim SEF from SEUSDVault
     * @param account The account for which to claim SEF
     */
    function claim(address account) external nonReentrant isActive {
        _withdraw(account, 0);
    }

    /**
     * @notice Low level withdraw function
     * @param account The account to withdraw from vault
     * @param _amount The amount to withdraw from vault
     */
    function _withdraw(address account, uint256 _amount) internal {
        UserInfo storage user = userInfo[account];
        require(user.amount >= _amount, "withdraw: not good");

        updateVault();
        updateAndPayOutPending(account); // Update balances of account this is not withdrawal but claiming SEF farmed

        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            seusd.safeTransfer(address(account), _amount);
        }
        user.rewardDebt = user.amount.mul(accSEFPerShare).div(1e18);

        emit Withdraw(account, _amount);
    }

    /**
     * @notice View function to see pending SEF on frontend
     * @param _user The user to see pending SEF
     * @return Amount of SEF the user can claim
     */
    function pendingSEF(address _user) public view returns (uint256) {
        UserInfo storage user = userInfo[_user];

        return user.amount.mul(accSEFPerShare).div(1e18).sub(user.rewardDebt);
    }

    /**
     * @notice Update and pay out pending SEF to user
     * @param account The user to pay out
     */
    function updateAndPayOutPending(address account) internal {
        uint256 pending = pendingSEF(account);

        if (pending > 0) {
            safeSEFTransfer(account, pending);
        }
    }

    /**
     * @notice Safe SEF transfer function, just in case if rounding error causes pool to not have enough SEF
     * @param _to The address that SEF to be transfered
     * @param _amount The amount that SEF to be transfered
     */
    function safeSEFTransfer(address _to, uint256 _amount) internal {
        uint256 sefBal = sef.balanceOf(address(this));

        if (_amount > sefBal) {
            sef.transfer(_to, sefBal);
            sefBalance = sef.balanceOf(address(this));
        } else {
            sef.transfer(_to, _amount);
            sefBalance = sef.balanceOf(address(this));
        }
    }

    /**
     * @notice Function that updates pending rewards
     */
    function updatePendingRewards() public isActive {
        uint256 newRewards = sef.balanceOf(address(this)).sub(sefBalance);

        if (newRewards > 0) {
            sefBalance = sef.balanceOf(address(this)); // If there is no change the balance didn't change
            pendingRewards = pendingRewards.add(newRewards);
        }
    }

    /**
     * @notice Update reward variables to be up-to-date
     */
    function updateVault() internal {
        updatePendingRewards();

        uint256 seusdBalance = seusd.balanceOf(address(this));
        if (seusdBalance == 0) {
            // avoids division by 0 errors
            return;
        }

        accSEFPerShare = accSEFPerShare.add(pendingRewards.mul(1e18).div(seusdBalance));
        pendingRewards = 0;
    }

    /*** Admin Functions ***/

    function _become(ISEUSDVaultProxy seusdVaultProxy) external {
        require(msg.sender == seusdVaultProxy.admin(), "only proxy admin can change brains");
        require(seusdVaultProxy._acceptImplementation() == 0, "change not authorized");
    }

    function setSegmentInfo(address _sef, address _vai) external onlyAdmin {
        require(_sef != address(0) && _vai != address(0), "addresses must not be zero");
        require(address(sef) == address(0) && address(seusd) == address(0), "addresses already set");
        sef = IBEP20(_sef);
        seusd = IBEP20(_vai);

        _notEntered = true;
    }

    /**
     * @notice Sets the address of the access control of this contract
     * @dev Admin function to set the access control address
     * @param newAccessControlAddress New address for the access control
     */
    function setAccessControl(address newAccessControlAddress) external onlyAdmin {
        _setAccessControlManager(newAccessControlAddress);
    }
}
