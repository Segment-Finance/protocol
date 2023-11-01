pragma solidity ^0.8.20;


import "../Tokens/SeTokens/SeToken.sol";

interface ComptrollerLensInterface {
    function liquidateCalculateSeizeTokens(
        address comptroller,
        address seTokenBorrowed,
        address seTokenCollateral,
        uint actualRepayAmount
    ) external view returns (uint, uint);

    function liquidateSEUSDCalculateSeizeTokens(
        address comptroller,
        address seTokenCollateral,
        uint actualRepayAmount
    ) external view returns (uint, uint);

    function getHypotheticalAccountLiquidity(
        address comptroller,
        address account,
        SeToken seTokenModify,
        uint redeemTokens,
        uint borrowAmount
    ) external view returns (uint, uint, uint);
}
