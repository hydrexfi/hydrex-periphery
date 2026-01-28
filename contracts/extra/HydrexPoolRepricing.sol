// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../interfaces/ISwapRouter.sol";
import "../interfaces/INonfungiblePositionManager.sol";
import "../interfaces/IAlgebraPool.sol";

/*
    __  __          __                 _____ 
   / / / /_  ______/ /_______  _  __  / __(_)
  / /_/ / / / / __  / ___/ _ \| |/_/ / /_/ / 
 / __  / /_/ / /_/ / /  /  __/>  <_ / __/ /  
/_/ /_/\__, /\__,_/_/   \___/_/|_(_)_/ /_/   
      /____/                                 

*/

/// @title HydrexPoolRepricing
/// @notice Atomically adds liquidity, swaps to reprice a pool, and removes liquidity
contract HydrexPoolRepricing {
    INonfungiblePositionManager public immutable nonfungiblePositionManager;
    ISwapRouter public immutable swapRouter;

    constructor() {
        nonfungiblePositionManager = INonfungiblePositionManager(0xC63E9672f8e93234C73cE954a1d1292e4103Ab86);
        swapRouter = ISwapRouter(0x6f4bE24d7dC93b6ffcBAb3Fd0747c5817Cea3F9e);
    }

    /// @notice Atomically adds liquidity, swaps to reprice, removes liquidity, and burns NFT
    /// @param poolAddress The address of the Algebra pool to reprice
    /// @param poolDeployer The pool deployer address (use address(0) for base pool)
    /// @param depositToken The token you're depositing (must be either token0 or token1)
    /// @param depositAmount The amount of depositToken to add as liquidity
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @param swapToken The token to swap through the new liquidity
    /// @param swapAmount The amount of swapToken to swap
    /// @return swapAmountOut The amount received from the swap
    /// @return collected0 The amount of token0 collected (liquidity + fees)
    /// @return collected1 The amount of token1 collected (liquidity + fees)
    /// @return finalLiquidity The pool's liquidity after repricing
    /// @return poolBalance0 The pool's token0 balance after repricing
    /// @return poolBalance1 The pool's token1 balance after repricing
    /// @return communityFee0 The pool's pending community fee for token0
    /// @return communityFee1 The pool's pending community fee for token1
    function reprice(
        address poolAddress,
        address poolDeployer,
        address depositToken,
        uint256 depositAmount,
        int24 tickLower,
        int24 tickUpper,
        address swapToken,
        uint256 swapAmount
    )
        external
        returns (
            uint256 swapAmountOut,
            uint256 collected0,
            uint256 collected1,
            uint128 finalLiquidity,
            uint256 poolBalance0,
            uint256 poolBalance1,
            uint128 communityFee0,
            uint128 communityFee1
        )
    {
        // Get token0 and token1 from the pool
        IAlgebraPool pool = IAlgebraPool(poolAddress);
        address token0 = pool.token0();
        address token1 = pool.token1();

        require(depositToken == token0 || depositToken == token1, "Invalid deposit token");
        require(swapToken == token0 || swapToken == token1, "Invalid swap token");

        // Transfer deposit token from sender
        IERC20(depositToken).transferFrom(msg.sender, address(this), depositAmount);

        // Approve position manager
        IERC20(depositToken).approve(address(nonfungiblePositionManager), depositAmount);

        // Prepare mint params - NFT minted to this contract for atomic removal
        uint256 amount0Desired = depositToken == token0 ? depositAmount : 0;
        uint256 amount1Desired = depositToken == token1 ? depositAmount : 0;

        INonfungiblePositionManager.MintParams memory mintParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            deployer: poolDeployer,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: amount0Desired,
            amount1Desired: amount1Desired,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });

        // Mint position
        (uint256 tokenId, uint128 liquidity, uint256 amount0Used, uint256 amount1Used) = nonfungiblePositionManager
            .mint(mintParams);

        // Refund unused deposit tokens
        if (depositToken == token0 && amount0Used < depositAmount) {
            IERC20(token0).transfer(msg.sender, depositAmount - amount0Used);
        } else if (depositToken == token1 && amount1Used < depositAmount) {
            IERC20(token1).transfer(msg.sender, depositAmount - amount1Used);
        }

        // Transfer swap token from sender
        IERC20(swapToken).transferFrom(msg.sender, address(this), swapAmount);

        // Approve router
        IERC20(swapToken).approve(address(swapRouter), swapAmount);

        // Execute swap
        address tokenOut = swapToken == token0 ? token1 : token0;

        ISwapRouter.ExactInputSingleParams memory swapParams = ISwapRouter.ExactInputSingleParams({
            tokenIn: swapToken,
            tokenOut: tokenOut,
            deployer: poolDeployer,
            recipient: msg.sender,
            deadline: block.timestamp,
            amountIn: swapAmount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        swapAmountOut = swapRouter.exactInputSingle(swapParams);

        // Decrease liquidity to 0
        INonfungiblePositionManager.DecreaseLiquidityParams memory decreaseParams = INonfungiblePositionManager
            .DecreaseLiquidityParams({
                tokenId: tokenId,
                liquidity: liquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            });

        nonfungiblePositionManager.decreaseLiquidity(decreaseParams);

        // Collect all tokens (liquidity + fees) and send to msg.sender
        INonfungiblePositionManager.CollectParams memory collectParams = INonfungiblePositionManager.CollectParams({
            tokenId: tokenId,
            recipient: msg.sender,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (collected0, collected1) = nonfungiblePositionManager.collect(collectParams);

        // Burn the NFT
        nonfungiblePositionManager.burn(tokenId);

        // Get final pool liquidity and ensure it's 0 (all liquidity removed)
        finalLiquidity = pool.liquidity();
        require(finalLiquidity == 0, "Pool liquidity must be 0 after repricing");

        // Check pool token balances for any remaining dust
        poolBalance0 = IERC20(token0).balanceOf(poolAddress);
        poolBalance1 = IERC20(token1).balanceOf(poolAddress);

        // Check pending community fees
        (communityFee0, communityFee1) = pool.getCommunityFeePending();
    }
}
