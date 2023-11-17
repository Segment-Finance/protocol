// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import "./IAccessControlManagerV8.sol";

/**
 * @title Segment Access Control Contract.
 * @dev The AccessControlledV8 contract is a wrapper around the OpenZeppelin AccessControl contract
 *      It provides a standardized way to control access to methods within the Segment Smart Contract Ecosystem.
 *      The contract allows the owner to set an AccessControlManager contract address.
 *      It can restrict method calls based on the sender's role and the method's signature.
 */

abstract contract AccessControlledV8 is Initializable, Ownable2StepUpgradeable {
    /// @notice Access control manager contract
    IAccessControlManagerV8 private _accessControlManager;

    /**
     * @dev This empty reserved space is put in place to allow future versions to add new
     * variables without shifting down storage in the inheritance chain.
     * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
     */
    uint256[49] private __gap;

    /// @notice Emitted when access control manager contract address is changed
    event NewAccessControlManager(address oldAccessControlManager, address newAccessControlManager);

    /// @notice Thrown when the action is prohibited by AccessControlManager
    error Unauthorized(address sender, address calledContract, string methodSignature);

    function __AccessControlled_init(address accessControlManager_) internal onlyInitializing {
        __Ownable_init_unchained(msg.sender);
        __AccessControlled_init_unchained(accessControlManager_);
    }

    function __AccessControlled_init_unchained(address accessControlManager_) internal onlyInitializing {
        _setAccessControlManager(accessControlManager_);
    }

    /**
     * @notice Sets the address of AccessControlManager
     * @dev Admin function to set address of AccessControlManager
     * @param accessControlManager_ The new address of the AccessControlManager
     * @custom:event Emits NewAccessControlManager event
     * @custom:access Only Governance
     */
    function setAccessControlManager(address accessControlManager_) external onlyOwner {
        _setAccessControlManager(accessControlManager_);
    }

    /**
     * @notice Returns the address of the access control manager contract
     */
    function accessControlManager() external view returns (IAccessControlManagerV8) {
        return _accessControlManager;
    }

    /**
     * @dev Internal function to set address of AccessControlManager
     * @param accessControlManager_ The new address of the AccessControlManager
     */
    function _setAccessControlManager(address accessControlManager_) internal {
        require(address(accessControlManager_) != address(0), "invalid acess control manager address");
        address oldAccessControlManager = address(_accessControlManager);
        _accessControlManager = IAccessControlManagerV8(accessControlManager_);
        emit NewAccessControlManager(oldAccessControlManager, accessControlManager_);
    }

    /**
     * @notice Reverts if the call is not allowed by AccessControlManager
     * @param signature Method signature
     */
    function _checkAccessAllowed(string memory signature) internal view {
        bool isAllowedToCall = _accessControlManager.isAllowedToCall(msg.sender, signature);

        if (!isAllowedToCall) {
            revert Unauthorized(msg.sender, address(this), signature);
        }
    }
}
