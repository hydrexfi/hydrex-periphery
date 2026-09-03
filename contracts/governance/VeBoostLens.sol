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

interface IVotes {
    function getVotes(address account) external view returns (uint256);
}

/**
 * @title VeBoostLens
 * @notice Earning power for veHYDX holders: raw voting power scaled by a fixed boost.
 *         Intended for use as a Snapshot `contract-call` strategy.
 * @dev The escrow's `getVotes` reads `block.timestamp`, so an `eth_call` pinned to a
 *      historical block returns that block's voting power. Snapshot pins to the proposal
 *      snapshot block, which makes this safe to use for historical scoring.
 *
 *      The boost is a compile-time constant, not an owner-settable value: a mutable
 *      multiplier on a governance input is a live attack surface. Changing the rate means
 *      deploying a new lens and repointing the Snapshot strategy, which is visible in the
 *      space config.
 *
 *      Earning power is defined as 1.3x votes; BOOST_BPS is the single source of that rate.
 *
 *      Invariant: getEarningPower(a) == rawVotes(a) * BOOST_BPS / BPS_DENOMINATOR
 *      Invariant: getEarningPower(a) >= rawVotes(a) for BOOST_BPS >= BPS_DENOMINATOR
 */
contract VeBoostLens {
    /// @notice The veHYDX voting escrow this lens reads from.
    IVotes public immutable veNFT;

    /// @notice Boost applied to raw voting power to yield earning power, in basis
    ///         points. 13_000 == 1.3x.
    uint256 public constant BOOST_BPS = 13_000;

    /// @notice Basis-point denominator.
    uint256 public constant BPS_DENOMINATOR = 10_000;

    error ZeroAddress();

    constructor(address _veNFT) {
        if (_veNFT == address(0)) revert ZeroAddress();
        veNFT = IVotes(_veNFT);
    }

    /**
     * @notice Earning power for an account: its veHYDX voting power scaled by BOOST_BPS.
     * @dev Rounds down. Multiplication precedes division to preserve precision.
     * @param _account The account to query.
     * @return The account's earning power.
     */
    function getEarningPower(address _account) external view returns (uint256) {
        return (veNFT.getVotes(_account) * BOOST_BPS) / BPS_DENOMINATOR;
    }

    /**
     * @notice Earning power for several accounts.
     * @param _accounts The accounts to query.
     * @return powers Earning power for each account, in the order given.
     */
    function getBatchEarningPower(address[] calldata _accounts) external view returns (uint256[] memory powers) {
        powers = new uint256[](_accounts.length);
        for (uint256 i = 0; i < _accounts.length; i++) {
            powers[i] = (veNFT.getVotes(_accounts[i]) * BOOST_BPS) / BPS_DENOMINATOR;
        }
    }

    /**
     * @notice Unboosted veHYDX voting power, passed through from the escrow.
     * @dev Exposed so earning power can be verified on-chain against its input.
     * @param _account The account to query.
     * @return The account's raw voting power.
     */
    function rawVotes(address _account) external view returns (uint256) {
        return veNFT.getVotes(_account);
    }
}
