// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/*
    __  __          __                 _____ 
   / / / /_  ______/ /_______  _  __  / __(_)
  / /_/ / / / / __  / ___/ _ \| |/_/ / /_/ / 
 / __  / /_/ / /_/ / /  /  __/>  <_ / __/ /  
/_/ /_/\__, /\__,_/_/   \___/_/|_(_)_/ /_/   
      /____/                                 

*/

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IBribe {
    function notifyRewardAmount(address _rewardsToken, uint256 reward) external;
}

/**
 * @title MultiBribeAllocator
 * @notice Contract for bulk allocation of bribe rewards across multiple bribe contracts
 */
contract MultiBribeAllocator {
    using SafeERC20 for IERC20;

    /// @notice Structure containing bribe placement information
    struct BribePlacement {
        address bribe; // Address of the bribe contract
        uint256 amount; // Amount of reward tokens to allocate
    }

    /**
     * @notice Bulk approve and notify bribe rewards across multiple bribe contracts
     * @dev Transfers tokens from caller, approves bribe contracts, and notifies them of rewards
     * @param rewardToken Address of the token to be used for all bribes
     * @param bribePlacements Array of bribe placements containing bribe contract address and amount
     */
    function bulkApproveAndNotify(address rewardToken, BribePlacement[] calldata bribePlacements) external {
        IERC20 token = IERC20(rewardToken);
        uint256 len = bribePlacements.length;
        for (uint256 i = 0; i < len; i++) {
            BribePlacement calldata placement = bribePlacements[i];

            // Pull tokens from sender
            token.safeTransferFrom(msg.sender, address(this), placement.amount);

            // Approve bribe to pull tokens from this contract
            token.approve(placement.bribe, placement.amount);

            // Notify bribe - it will pull the tokens from this contract
            IBribe(placement.bribe).notifyRewardAmount(rewardToken, placement.amount);
        }
    }
}
