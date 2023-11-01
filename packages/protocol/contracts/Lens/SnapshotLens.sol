pragma solidity ^0.8.20;


import "../Tokens/SeTokens/SeToken.sol";
import "../Utils/SafeMath.sol";
import "../Comptroller/ComptrollerInterface.sol";
import "../Tokens/EIP20Interface.sol";
import "../Tokens/SeTokens/SeBep20.sol";

contract SnapshotLens is ExponentialNoError {
    using SafeMath for uint256;

    struct AccountSnapshot {
        address account;
        string assetName;
        address seTokenAddress;
        address underlyingAssetAddress;
        uint256 supply;
        uint256 supplyInUsd;
        uint256 collateral;
        uint256 borrows;
        uint256 borrowsInUsd;
        uint256 assetPrice;
        uint256 accruedInterest;
        uint seTokenDecimals;
        uint underlyingDecimals;
        uint exchangeRate;
        bool isACollateral;
    }

    /** Snapshot calculation **/
    /**
     * @dev Local vars for avoiding stack-depth limits in calculating account snapshot.
     *  Note that `seTokenBalance` is the number of seTokens the account owns in the market,
     *  whereas `borrowBalance` is the amount of underlying that the account has borrowed.
     */
    struct AccountSnapshotLocalVars {
        uint collateral;
        uint seTokenBalance;
        uint borrowBalance;
        uint borrowsInUsd;
        uint balanceOfUnderlying;
        uint supplyInUsd;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
        bool isACollateral;
    }

    function getAccountSnapshot(
        address payable account,
        address comptrollerAddress
    ) public returns (AccountSnapshot[] memory) {
        // For each asset the account is in
        SeToken[] memory assets = ComptrollerInterface(comptrollerAddress).getAllMarkets();
        AccountSnapshot[] memory accountSnapshots = new AccountSnapshot[](assets.length);
        for (uint256 i = 0; i < assets.length; ++i) {
            accountSnapshots[i] = getAccountSnapshot(account, comptrollerAddress, assets[i]);
        }
        return accountSnapshots;
    }

    function isACollateral(address account, address asset, address comptrollerAddress) public view returns (bool) {
        SeToken[] memory assetsAsCollateral = ComptrollerInterface(comptrollerAddress).getAssetsIn(account);
        for (uint256 j = 0; j < assetsAsCollateral.length; ++j) {
            if (address(assetsAsCollateral[j]) == asset) {
                return true;
            }
        }

        return false;
    }

    function getAccountSnapshot(
        address payable account,
        address comptrollerAddress,
        SeToken seToken
    ) public returns (AccountSnapshot memory) {
        AccountSnapshotLocalVars memory vars; // Holds all our calculation results
        uint oErr;

        // Read the balances and exchange rate from the seToken
        (oErr, vars.seTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = seToken.getAccountSnapshot(account);
        require(oErr == 0, "Snapshot Error");
        vars.exchangeRate = Exp({ mantissa: vars.exchangeRateMantissa });

        (, uint collateralFactorMantissa) = ComptrollerInterface(comptrollerAddress).markets(address(seToken));
        vars.collateralFactor = Exp({ mantissa: collateralFactorMantissa });

        // Get the normalized price of the asset
        vars.oraclePriceMantissa = ComptrollerInterface(comptrollerAddress).oracle().getUnderlyingPrice(seToken);
        vars.oraclePrice = Exp({ mantissa: vars.oraclePriceMantissa });

        // Pre-compute a conversion factor from tokens -> bnb (normalized price value)
        vars.tokensToDenom = mul_(mul_(vars.collateralFactor, vars.exchangeRate), vars.oraclePrice);

        //Collateral = tokensToDenom * seTokenBalance
        vars.collateral = mul_ScalarTruncate(vars.tokensToDenom, vars.seTokenBalance);

        vars.balanceOfUnderlying = seToken.balanceOfUnderlying(account);
        vars.supplyInUsd = mul_ScalarTruncate(vars.oraclePrice, vars.balanceOfUnderlying);

        vars.borrowsInUsd = mul_ScalarTruncate(vars.oraclePrice, vars.borrowBalance);

        address underlyingAssetAddress;
        uint underlyingDecimals;

        if (compareStrings(seToken.symbol(), "seBNB")) {
            underlyingAssetAddress = address(0);
            underlyingDecimals = 18;
        } else {
            SeBep20 seBep20 = SeBep20(address(seToken));
            underlyingAssetAddress = seBep20.underlying();
            underlyingDecimals = EIP20Interface(seBep20.underlying()).decimals();
        }

        vars.isACollateral = isACollateral(account, address(seToken), comptrollerAddress);

        return
            AccountSnapshot({
                account: account,
                assetName: seToken.name(),
                seTokenAddress: address(seToken),
                underlyingAssetAddress: underlyingAssetAddress,
                supply: vars.balanceOfUnderlying,
                supplyInUsd: vars.supplyInUsd,
                collateral: vars.collateral,
                borrows: vars.borrowBalance,
                borrowsInUsd: vars.borrowsInUsd,
                assetPrice: vars.oraclePriceMantissa,
                accruedInterest: seToken.borrowIndex(),
                seTokenDecimals: seToken.decimals(),
                underlyingDecimals: underlyingDecimals,
                exchangeRate: seToken.exchangeRateCurrent(),
                isACollateral: vars.isACollateral
            });
    }

    // utilities
    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return (keccak256(abi.encodePacked((a))) == keccak256(abi.encodePacked((b))));
    }
}
