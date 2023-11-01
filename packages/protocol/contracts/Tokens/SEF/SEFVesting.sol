pragma solidity ^0.8.20;

import "../../Utils/IBEP20.sol";
import "../../Utils/SafeBEP20.sol";
import "./SEFVestingStorage.sol";
import "./SEFVestingProxy.sol";

/**
 * @title Segment's SEFVesting Contract
 * @author Segment
 */
contract SEFVesting is SEFVestingStorage {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    /// @notice total vesting period for 1 year in seconds
    uint256 public constant TOTAL_VESTING_TIME = 365 * 24 * 60 * 60;

    /// @notice decimal precision for SEF
    uint256 public constant sefDecimalsMultiplier = 1e18;

    /// @notice Emitted when SEFVested is claimed by recipient
    event VestedTokensClaimed(address recipient, uint256 amountClaimed);

    /// @notice Emitted when srtConversionAddress is set
    event SRTConversionSet(address srtConversionAddress);

    /// @notice Emitted when SEF is deposited for vesting
    event SEFVested(address indexed recipient, uint256 startTime, uint256 amount, uint256 withdrawnAmount);

    /// @notice Emitted when SEF is withdrawn by recipient
    event SEFWithdrawn(address recipient, uint256 amount);

    modifier nonZeroAddress(address _address) {
        require(_address != address(0), "Address cannot be Zero");
        _;
    }

    /**
     * @notice initialize SEFVestingStorage
     * @param _sefAddress The SEFToken address
     */
    function initialize(address _sefAddress) public {
        require(msg.sender == admin, "only admin may initialize the SEFVesting");
        require(initialized == false, "SEFVesting is already initialized");
        require(_sefAddress != address(0), "_sefAddress cannot be Zero");
        sef = IBEP20(_sefAddress);

        _notEntered = true;
        initialized = true;
    }

    modifier isInitialized() {
        require(initialized == true, "SEFVesting is not initialized");
        _;
    }

    /**
     * @notice sets SRTConverter Address
     * @dev Note: If SRTConverter is not set, then Vesting is not allowed
     * @param _srtConversionAddress The SRTConverterProxy Address
     */
    function setSRTConverter(address _srtConversionAddress) public {
        require(msg.sender == admin, "only admin may initialize the Vault");
        require(_srtConversionAddress != address(0), "srtConversionAddress cannot be Zero");
        srtConversionAddress = _srtConversionAddress;
        emit SRTConversionSet(_srtConversionAddress);
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    modifier onlySrtConverter() {
        require(msg.sender == srtConversionAddress, "only SRTConversion Address can call the function");
        _;
    }

    modifier vestingExistCheck(address recipient) {
        require(vestings[recipient].length > 0, "recipient doesnot have any vestingRecord");
        _;
    }

    /**
     * @notice Deposit SEF for Vesting
     * @param recipient The vesting recipient
     * @param depositAmount SEF amount for deposit
     */
    function deposit(
        address recipient,
        uint depositAmount
    ) external isInitialized onlySrtConverter nonZeroAddress(recipient) {
        require(depositAmount > 0, "Deposit amount must be non-zero");

        VestingRecord[] storage vestingsOfRecipient = vestings[recipient];

        VestingRecord memory vesting = VestingRecord({
            recipient: recipient,
            startTime: getCurrentTime(),
            amount: depositAmount,
            withdrawnAmount: 0
        });

        vestingsOfRecipient.push(vesting);

        emit SEFVested(recipient, vesting.startTime, vesting.amount, vesting.withdrawnAmount);
    }

    /**
     * @notice Withdraw Vested SEF of recipient
     */
    function withdraw() external isInitialized vestingExistCheck(msg.sender) {
        address recipient = msg.sender;
        VestingRecord[] storage vestingsOfRecipient = vestings[recipient];
        uint256 vestingCount = vestingsOfRecipient.length;
        uint256 totalWithdrawableAmount = 0;

        for (uint i = 0; i < vestingCount; ++i) {
            VestingRecord storage vesting = vestingsOfRecipient[i];
            (, uint256 toWithdraw) = calculateWithdrawableAmount(
                vesting.amount,
                vesting.startTime,
                vesting.withdrawnAmount
            );
            if (toWithdraw > 0) {
                totalWithdrawableAmount = totalWithdrawableAmount.add(toWithdraw);
                vesting.withdrawnAmount = vesting.withdrawnAmount.add(toWithdraw);
            }
        }

        if (totalWithdrawableAmount > 0) {
            uint256 sefBalance = sef.balanceOf(address(this));
            require(sefBalance >= totalWithdrawableAmount, "Insufficient SEF for withdrawal");
            emit SEFWithdrawn(recipient, totalWithdrawableAmount);
            sef.safeTransfer(recipient, totalWithdrawableAmount);
        }
    }

    /**
     * @notice get Withdrawable SEF Amount
     * @param recipient The vesting recipient
     * @dev returns A tuple with totalWithdrawableAmount , totalVestedAmount and totalWithdrawnAmount
     */
    function getWithdrawableAmount(
        address recipient
    )
        public
        view
        isInitialized
        nonZeroAddress(recipient)
        vestingExistCheck(recipient)
        returns (uint256 totalWithdrawableAmount, uint256 totalVestedAmount, uint256 totalWithdrawnAmount)
    {
        VestingRecord[] storage vestingsOfRecipient = vestings[recipient];
        uint256 vestingCount = vestingsOfRecipient.length;

        for (uint i = 0; i < vestingCount; i++) {
            VestingRecord storage vesting = vestingsOfRecipient[i];
            (uint256 vestedAmount, uint256 toWithdraw) = calculateWithdrawableAmount(
                vesting.amount,
                vesting.startTime,
                vesting.withdrawnAmount
            );
            totalVestedAmount = totalVestedAmount.add(vestedAmount);
            totalWithdrawableAmount = totalWithdrawableAmount.add(toWithdraw);
            totalWithdrawnAmount = totalWithdrawnAmount.add(vesting.withdrawnAmount);
        }

        return (totalWithdrawableAmount, totalVestedAmount, totalWithdrawnAmount);
    }

    /**
     * @notice get Withdrawable SEF Amount
     * @param amount Amount deposited for vesting
     * @param vestingStartTime time in epochSeconds at the time of vestingDeposit
     * @param withdrawnAmount SEFAmount withdrawn from VestedAmount
     * @dev returns A tuple with vestedAmount and withdrawableAmount
     */
    function calculateWithdrawableAmount(
        uint256 amount,
        uint256 vestingStartTime,
        uint256 withdrawnAmount
    ) internal view returns (uint256, uint256) {
        uint256 vestedAmount = calculateVestedAmount(amount, vestingStartTime, getCurrentTime());
        uint toWithdraw = vestedAmount.sub(withdrawnAmount);
        return (vestedAmount, toWithdraw);
    }

    /**
     * @notice calculate total vested amount
     * @param vestingAmount Amount deposited for vesting
     * @param vestingStartTime time in epochSeconds at the time of vestingDeposit
     * @param currentTime currentTime in epochSeconds
     * @return Total SEF amount vested
     */
    function calculateVestedAmount(
        uint256 vestingAmount,
        uint256 vestingStartTime,
        uint256 currentTime
    ) internal view returns (uint256) {
        if (currentTime < vestingStartTime) {
            return 0;
        } else if (currentTime > vestingStartTime.add(TOTAL_VESTING_TIME)) {
            return vestingAmount;
        } else {
            return (vestingAmount.mul(currentTime.sub(vestingStartTime))).div(TOTAL_VESTING_TIME);
        }
    }

    /**
     * @notice current block timestamp
     * @return blocktimestamp
     */
    function getCurrentTime() public view returns (uint256) {
        return block.timestamp;
    }

    /*** Admin Functions ***/
    function _become(SEFVestingProxy sefVestingProxy) public {
        require(msg.sender == sefVestingProxy.admin(), "only proxy admin can change brains");
        sefVestingProxy._acceptImplementation();
    }
}
