pragma solidity ^0.8.20;

import "../SeTokens/SeTokenInterfaces.sol";

abstract contract SEUSDControllerInterface {
    function getSEUSDAddress() virtual public view returns (address);

    function getMintableSEUSD(address minter) virtual public view returns (uint, uint);

    function mintSEUSD(address minter, uint mintSEUSDAmount) virtual external returns (uint);

    function repaySEUSD(address repayer, uint repaySEUSDAmount) virtual external returns (uint);

    function liquidateSEUSD(
        address borrower,
        uint repayAmount,
        SeTokenInterface seTokenCollateral
    ) virtual external returns (uint, uint);

    function _initializeSegmentSEUSDState(uint blockNumber) virtual external returns (uint);

    function updateSegmentSEUSDMintIndex() virtual external returns (uint);

    function calcDistributeSEUSDMinterSegment(address seusdMinter) virtual external returns (uint, uint, uint, uint);

    function getSEUSDRepayAmount(address account) virtual public view returns (uint);
}
