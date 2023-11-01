pragma solidity ^0.8.20;

import "../../Utils/IBEP20.sol";
import "../../Utils/SafeBEP20.sol";
import "../SEF/ISEFVesting.sol";
import "./SRTConverterStorage.sol";
import "./SRTConverterProxy.sol";

/**
 * @title Segment's SRTConversion Contract
 * @author Segment
 */
contract SRTConverter is SRTConverterStorage {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    address public constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice decimal precision for SRT
    uint256 public constant srtDecimalsMultiplier = 1e18;

    /// @notice decimal precision for SEF
    uint256 public constant sefDecimalsMultiplier = 1e18;

    /// @notice Emitted when an admin set conversion info
    event ConversionInfoSet(
        uint256 conversionRatio,
        uint256 conversionStartTime,
        uint256 conversionPeriod,
        uint256 conversionEndTime
    );

    /// @notice Emitted when token conversion is done
    event TokenConverted(
        address reedeemer,
        address srtAddress,
        uint256 srtAmount,
        address sefAddress,
        uint256 sefAmount
    );

    /// @notice Emitted when an admin withdraw converted token
    event TokenWithdraw(address token, address to, uint256 amount);

    /// @notice Emitted when SEFVestingAddress is set
    event SEFVestingSet(address sefVestingAddress);

    function initialize(
        address _srtAddress,
        address _sefAddress,
        uint256 _conversionRatio,
        uint256 _conversionStartTime,
        uint256 _conversionPeriod
    ) public {
        require(msg.sender == admin, "only admin may initialize the SRTConverter");
        require(initialized == false, "SRTConverter is already initialized");

        require(_srtAddress != address(0), "srtAddress cannot be Zero");
        srt = IBEP20(_srtAddress);

        require(_sefAddress != address(0), "sefAddress cannot be Zero");
        sef = IBEP20(_sefAddress);

        require(_conversionRatio > 0, "conversionRatio cannot be Zero");
        conversionRatio = _conversionRatio;

        require(_conversionStartTime >= block.timestamp, "conversionStartTime must be time in the future");
        require(_conversionPeriod > 0, "_conversionPeriod is invalid");

        conversionStartTime = _conversionStartTime;
        conversionPeriod = _conversionPeriod;
        conversionEndTime = conversionStartTime.add(conversionPeriod);
        emit ConversionInfoSet(conversionRatio, conversionStartTime, conversionPeriod, conversionEndTime);

        totalSrtConverted = 0;
        _notEntered = true;
        initialized = true;
    }

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
     * @notice sets SEFVestingProxy Address
     * @dev Note: If SEFVestingProxy is not set, then Conversion is not allowed
     * @param _sefVestingAddress The SEFVestingProxy Address
     */
    function setSEFVesting(address _sefVestingAddress) public {
        require(msg.sender == admin, "only admin may initialize the Vault");
        require(_sefVestingAddress != address(0), "sefVestingAddress cannot be Zero");
        sefVesting = ISEFVesting(_sefVestingAddress);
        emit SEFVestingSet(_sefVestingAddress);
    }

    modifier isInitialized() {
        require(initialized == true, "SRTConverter is not initialized");
        _;
    }

    function isConversionActive() public view returns (bool) {
        uint256 currentTime = block.timestamp;
        if (currentTime >= conversionStartTime && currentTime <= conversionEndTime) {
            return true;
        }
        return false;
    }

    modifier checkForActiveConversionPeriod() {
        uint256 currentTime = block.timestamp;
        require(currentTime >= conversionStartTime, "Conversion did not start yet");
        require(currentTime <= conversionEndTime, "Conversion Period Ended");
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == admin, "only admin can");
        _;
    }

    modifier nonZeroAddress(address _address) {
        require(_address != address(0), "Address cannot be Zero");
        _;
    }

    /**
     * @notice Transfer SRT and redeem SEF
     * @dev Note: If there is not enough SEF, we do not perform the conversion.
     * @param srtAmount The amount of SRT
     */
    function convert(uint256 srtAmount) external isInitialized checkForActiveConversionPeriod nonReentrant {
        require(
            address(sefVesting) != address(0) && address(sefVesting) != DEAD_ADDRESS,
            "SEF-Vesting Address is not set"
        );
        require(srtAmount > 0, "SRT amount must be non-zero");
        totalSrtConverted = totalSrtConverted.add(srtAmount);

        uint256 redeemAmount = srtAmount.mul(conversionRatio).mul(sefDecimalsMultiplier).div(1e18).div(
            srtDecimalsMultiplier
        );

        emit TokenConverted(msg.sender, address(srt), srtAmount, address(sef), redeemAmount);
        srt.safeTransferFrom(msg.sender, DEAD_ADDRESS, srtAmount);
        sefVesting.deposit(msg.sender, redeemAmount);
    }

    /*** Admin Functions ***/
    function _become(SRTConverterProxy srtConverterProxy) public {
        require(msg.sender == srtConverterProxy.admin(), "only proxy admin can change brains");
        srtConverterProxy._acceptImplementation();
    }
}
