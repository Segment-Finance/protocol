// SPDX-License-Identifier: BSD-3-Clause
pragma solidity 0.8.20;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { IProtocolShareReserve } from "./IProtocolShareReserve.sol";
import { ExponentialNoError } from "../ExponentialNoError.sol";
import { ReserveHelpers } from "./ReserveHelpers.sol";
import { IRiskFund } from "./IRiskFund.sol";
import { ensureNonzeroAddress } from "../lib/validators.sol";

contract ProtocolShareReserve is ExponentialNoError, ReserveHelpers, IProtocolShareReserve {
    using SafeERC20 for IERC20;

    address public protocolIncome;
    address public riskFund;
    // Percentage of funds not sent to the RiskFund contract when the funds are released, following the project Tokenomics
    uint256 private constant PROTOCOL_SHARE_PERCENTAGE = 50;
    uint256 private constant BASE_UNIT = 100;

    /// @notice Emitted when funds are released
    event FundsReleased(address indexed comptroller, address indexed asset, uint256 amount);

    /// @notice Emitted when pool registry address is updated
    event PoolRegistryUpdated(address indexed oldPoolRegistry, address indexed newPoolRegistry);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address corePoolComptroller_,
        address sebnb_,
        address nativeWrapped_
    ) ReserveHelpers(corePoolComptroller_, sebnb_, nativeWrapped_) {
        _disableInitializers();
    }

    /**
     * @notice Initializes the deployer to owner.
     * @param protocolIncome_ The address protocol income will be sent to
     * @param riskFund_ Risk fund address
     * @custom:error ZeroAddressNotAllowed is thrown when protocol income address is zero
     * @custom:error ZeroAddressNotAllowed is thrown when risk fund address is zero
     */
    function initialize(address protocolIncome_, address riskFund_) external initializer {
        ensureNonzeroAddress(protocolIncome_);
        ensureNonzeroAddress(riskFund_);

        __Ownable_init_unchained(msg.sender);

        protocolIncome = protocolIncome_;
        riskFund = riskFund_;
    }

    /**
     * @notice Pool registry setter.
     * @param poolRegistry_ Address of the pool registry
     * @custom:error ZeroAddressNotAllowed is thrown when pool registry address is zero
     */
    function setPoolRegistry(address poolRegistry_) external onlyOwner {
        ensureNonzeroAddress(poolRegistry_);
        address oldPoolRegistry = poolRegistry;
        poolRegistry = poolRegistry_;
        emit PoolRegistryUpdated(oldPoolRegistry, poolRegistry_);
    }

    /**
     * @notice Release funds
     * @param comptroller Pool's Comptroller
     * @param asset  Asset to be released
     * @param amount Amount to release
     * @return Number of total released tokens
     * @custom:error ZeroAddressNotAllowed is thrown when asset address is zero
     */
    function releaseFunds(address comptroller, address asset, uint256 amount) external nonReentrant returns (uint256) {
        ensureNonzeroAddress(asset);
        require(amount <= _poolsAssetsReserves[comptroller][asset], "ProtocolShareReserve: Insufficient pool balance");

        assetsReserves[asset] -= amount;
        _poolsAssetsReserves[comptroller][asset] -= amount;
        uint256 protocolIncomeAmount = mul_(
            Exp({ mantissa: amount }),
            div_(Exp({ mantissa: PROTOCOL_SHARE_PERCENTAGE * EXP_SCALE }), BASE_UNIT)
        ).mantissa;

        address riskFund_ = riskFund;

        emit FundsReleased(comptroller, asset, amount);

        IERC20(asset).safeTransfer(protocolIncome, protocolIncomeAmount);
        IERC20(asset).safeTransfer(riskFund_, amount - protocolIncomeAmount);

        // Update the pool asset's state in the risk fund for the above transfer.
        IRiskFund(riskFund_).updateAssetsState(comptroller, asset);

        return amount;
    }

    /**
     * @notice Update the reserve of the asset for the specific pool after transferring to the protocol share reserve.
     * @param comptroller  Comptroller address(pool)
     * @param asset Asset address.
     */
    function updateAssetsState(
        address comptroller,
        address asset
    ) public override(IProtocolShareReserve, ReserveHelpers) {
        super.updateAssetsState(comptroller, asset);
    }
}
