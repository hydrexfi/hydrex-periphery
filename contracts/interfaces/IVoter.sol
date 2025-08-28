// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IVoter {
    function claimFeesToRecipientByTokenId(
        address[] memory _fees,
        address[][] memory _tokens,
        uint256 _tokenId,
        address _recipient
    ) external;

    function claimBribesToRecipientByTokenId(
        address[] memory _bribes,
        address[][] memory _tokens,
        uint256 _tokenId,
        address _recipient
    ) external;

    function claimRewardTokensToRecipient(
        address[] memory _gauges,
        address[][] memory _tokens,
        address _claimFor,
        address _recipient
    ) external;

    function vote(address[] calldata _pool, uint256[] calldata _weights) external;
}
