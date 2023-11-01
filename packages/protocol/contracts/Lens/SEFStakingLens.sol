pragma solidity ^0.8.20;

import "../SEFVault/SEFVault.sol";
import "../Utils/IBEP20.sol";

contract SEFStakingLens {
    /**
     * @notice Get the SEF stake balance of an account
     * @param account The address of the account to check
     * @param sefAddress The address of the SEFToken
     * @param sefVaultProxyAddress The address of the SEFVaultProxy
     * @return stakedAmount The balance that user staked
     * @return pendingWithdrawalAmount pending withdrawal amount of user.
     */
    function getStakedData(
        address account,
        address sefAddress,
        address sefVaultProxyAddress
    ) external view returns (uint256 stakedAmount, uint256 pendingWithdrawalAmount) {
        SEFVault sefVaultInstance = SEFVault(sefVaultProxyAddress);
        uint256 poolLength = sefVaultInstance.poolLength(sefAddress);

        for (uint256 pid = 0; pid < poolLength; ++pid) {
            (IBEP20 token, , , , , , ) = sefVaultInstance.poolInfos(sefAddress, pid);
            if (address(token) == address(sefAddress)) {
                // solhint-disable-next-line no-unused-vars
                (uint256 userAmount, uint256 userRewardDebt, uint256 userPendingWithdrawals) = sefVaultInstance
                    .getUserInfo(sefAddress, pid, account);
                stakedAmount = userAmount;
                pendingWithdrawalAmount = userPendingWithdrawals;
                break;
            }
        }

        return (stakedAmount, pendingWithdrawalAmount);
    }
}
