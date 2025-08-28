// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IOptionsToken {
    /**
     * @notice Exercises options tokens to create a permanent voting escrow lock
     * @dev Burns option tokens and creates a permanent veNFT lock for the recipient
     * No payment is required as this creates a permanent lock which benefits the protocol
     * @param _amount The amount of option tokens to exercise and lock permanently
     * @param _recipient The address that will receive the voting escrow NFT
     * @return nftId The token ID of the newly created voting escrow NFT
     */
    function exerciseVe(
        uint256 _amount,
        address _recipient
    ) external returns (uint256 nftId);
}