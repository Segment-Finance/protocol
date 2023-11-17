// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.20;

interface IAmmSwapV2Router {
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256 swapAmount);

    function swapExactBNBForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapExactBNBForTokensAtSupportingFee(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256 swapAmount);

    function swapExactTokensForBNB(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForBNBAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256 swapAmount);

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapBNBForExactTokens(
        uint256 amountOut,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    function swapTokensForExactBNB(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactTokensForTokensAndSupply(
        address seTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external;

    function swapExactTokensForTokensAndSupplyAtSupportingFee(
        address seTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external;

    function swapExactBNBForTokensAndSupply(
        address seTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable;

    function swapExactBNBForTokensAndSupplyAtSupportingFee(
        address seTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable;

    function swapTokensForExactTokensAndSupply(
        address seTokenAddress,
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external;

    function swapBNBForExactTokensAndSupply(
        address seTokenAddress,
        uint256 amountOut,
        address[] calldata path,
        uint256 deadline
    ) external payable;

    function swapExactTokensForBNBAndSupply(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external;

    function swapExactTokensForBNBAndSupplyAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external;

    function swapTokensForExactBNBAndSupply(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external;

    function swapBNBForFullTokenDebtAndRepay(
        address seTokenAddress,
        address[] calldata path,
        uint256 deadline
    ) external payable;

    function swapExactTokensForTokensAndRepay(
        address seTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external;

    function swapExactTokensForTokensAndRepayAtSupportingFee(
        address seTokenAddress,
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external;

    function swapExactBNBForTokensAndRepay(
        address seTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable;

    function swapExactBNBForTokensAndRepayAtSupportingFee(
        address seTokenAddress,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external payable;

    function swapTokensForExactTokensAndRepay(
        address seTokenAddress,
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external;

    function swapTokensForFullTokenDebtAndRepay(
        address seTokenAddress,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external;

    function swapBNBForExactTokensAndRepay(
        address seTokenAddress,
        uint256 amountOut,
        address[] calldata path,
        uint256 deadline
    ) external payable;

    function swapExactTokensForBNBAndRepay(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external;

    function swapExactTokensForBNBAndRepayAtSupportingFee(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        uint256 deadline
    ) external;

    function swapTokensForExactBNBAndRepay(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        uint256 deadline
    ) external;

    function swapTokensForFullBNBDebtAndRepay(uint256 amountInMax, address[] calldata path, uint256 deadline) external;
}
