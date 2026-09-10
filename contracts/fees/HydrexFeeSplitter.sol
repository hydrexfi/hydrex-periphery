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
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IAlgebraPool, IHydrexGauge, IHydrexVoter, IHydrexFeeSplitterFactory} from "./interfaces/IFeeSplitterExternal.sol";

/**
 * @title HydrexFeeSplitter
 */
contract HydrexFeeSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    /* -----------------------------------------------------------------------
                                    DECLARATIONS
    ----------------------------------------------------------------------- */

    /// @notice Basis-point denominator used for the secondary share
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Upper bound on the secondary share, as a guard against a fat-fingered config
    uint16 public constant MAX_SECONDARY_SHARE_BPS = 2_000; // 20%

    /// @notice Factory that deployed this splitter; its owner administers this contract
    IHydrexFeeSplitterFactory public immutable factory;

    /// @notice Algebra pool whose community fees land here
    address public immutable pool;

    /// @notice Pool's token0
    address public immutable token0;

    /// @notice Pool's token1
    address public immutable token1;

    /// @notice Primary recipient override. Zero means "use the pool's gauge".
    address public primaryRecipientOverride;

    /// @notice Secondary recipient override. Zero means "use the factory default".
    address public secondaryRecipientOverride;

    /// @notice Secondary share override in bps. Zero means "use the factory default".
    /// @dev Consequence of using zero as the sentinel: a per-pool share of exactly 0% is not
    ///      expressible. Waiving the secondary cut is a fleet-wide decision
    ///      (`factory.setDefaultSecondaryShareBps(0)`), not a per-pool one.
    uint16 public secondaryShareBpsOverride;

    event Split(
        address indexed token,
        address indexed primaryRecipient,
        uint256 primaryAmount,
        address indexed secondaryRecipient,
        uint256 secondaryAmount
    );
    event GaugeFeesClaimed(address indexed gauge, uint256 claimed0, uint256 claimed1);
    event GaugeFeesClaimFailed(address indexed gauge);
    event PrimaryRecipientOverrideSet(address indexed previous, address indexed current);
    event SecondaryRecipientOverrideSet(address indexed previous, address indexed current);
    event SecondaryShareOverrideSet(uint16 previous, uint16 current);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event NativeRescued(address indexed to, uint256 amount);

    error NotFactoryOwner();
    error ZeroAddress();
    error ShareTooHigh();
    error NothingToRescue();
    error NoPrimaryRecipient();
    error NativeTransferFailed();

    /// @dev The factory itself is allowed through so its batch helpers work; every one of those
    ///      is `onlyOwner` on the factory, so this does not widen who can actually configure a
    ///      splitter — it only lets the owner act on many splitters in one transaction.
    modifier onlyFactoryOwner() {
        if (msg.sender != address(factory) && msg.sender != factory.owner()) revert NotFactoryOwner();
        _;
    }

    /**
     * @param _pool Algebra Integral pool to serve. Must expose `token0()`/`token1()`.
     * @dev The deployer becomes the administering factory, so this is meant to be deployed by
     *      `HydrexFeeSplitterFactory`. Deploying it directly leaves `factory.owner()` undefined.
     */
    constructor(address _pool) {
        if (_pool == address(0)) revert ZeroAddress();

        address _token0 = IAlgebraPool(_pool).token0();
        address _token1 = IAlgebraPool(_pool).token1();
        if (_token0 == address(0) || _token1 == address(0)) revert ZeroAddress();

        factory = IHydrexFeeSplitterFactory(msg.sender);
        pool = _pool;
        token0 = _token0;
        token1 = _token1;
    }

    /* -----------------------------------------------------------------------
                                       VIEWS
    ----------------------------------------------------------------------- */

    /// @notice The pool's current gauge, or zero while the pool has none
    function gauge() public view returns (address) {
        return IHydrexVoter(factory.voter()).gauges(pool);
    }

    /**
     * @notice Address receiving the primary share.
     * @dev Override first, then the pool's live gauge, then the factory's fallback recipient. The
     *      fallback keeps fees claimable for pools that have no gauge yet instead of stranding them.
     */
    function primaryRecipient() public view returns (address recipient) {
        recipient = primaryRecipientOverride;
        if (recipient != address(0)) return recipient;

        recipient = gauge();
        if (recipient != address(0)) return recipient;

        (, , recipient) = factory.defaults();
    }

    /// @notice Address receiving the secondary (Algebra) share. Zero disables the secondary cut.
    function secondaryRecipient() public view returns (address recipient) {
        recipient = secondaryRecipientOverride;
        if (recipient == address(0)) (recipient, , ) = factory.defaults();
    }

    /// @notice Secondary share in basis points, capped at `MAX_SECONDARY_SHARE_BPS`
    function secondaryShareBps() public view returns (uint16 shareBps) {
        shareBps = secondaryShareBpsOverride;
        if (shareBps == 0) (, shareBps, ) = factory.defaults();
        if (shareBps > MAX_SECONDARY_SHARE_BPS) shareBps = MAX_SECONDARY_SHARE_BPS;
    }

    /// @notice Full resolved state, for dashboards and ops tooling
    function config()
        external
        view
        returns (
            address _pool,
            address _gauge,
            address _token0,
            address _token1,
            address _primaryRecipient,
            address _secondaryRecipient,
            uint16 _secondaryShareBps,
            bool _isLiveCommunityVault
        )
    {
        _pool = pool;
        _gauge = gauge();
        _token0 = token0;
        _token1 = token1;
        _primaryRecipient = primaryRecipient();
        _secondaryRecipient = secondaryRecipient();
        _secondaryShareBps = secondaryShareBps();
        _isLiveCommunityVault = IAlgebraPool(pool).communityVault() == address(this);
    }

    /// @notice Balances currently sitting in this splitter, awaiting `split()`
    function pending() public view returns (uint256 balance0, uint256 balance1) {
        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));
    }

    /// @notice Fees still accumulating inside the pool, not yet pushed here
    function pendingInPool() external view returns (uint128 poolPending0, uint128 poolPending1) {
        return IAlgebraPool(pool).getCommunityFeePending();
    }

    /// @notice True when this splitter is the pool's live `communityVault`
    function isLiveCommunityVault() external view returns (bool) {
        return IAlgebraPool(pool).communityVault() == address(this);
    }

    /* -----------------------------------------------------------------------
                                       WRITES
    ----------------------------------------------------------------------- */

    /**
     * @notice Distribute everything held here between the primary and secondary recipients.
     * @dev Permissionless. Balance-driven, so calling it twice in a row is harmless and calling it
     *      on an empty splitter costs a few reads and does nothing.
     */
    function split()
        public
        nonReentrant
        returns (uint256 primary0, uint256 secondary0, uint256 primary1, uint256 secondary1)
    {
        address _primary = primaryRecipient();
        address _secondary = secondaryRecipient();
        uint16 shareBps = _secondary == address(0) ? 0 : secondaryShareBps();

        (primary0, secondary0) = _splitToken(token0, _primary, _secondary, shareBps);
        (primary1, secondary1) = _splitToken(token1, _primary, _secondary, shareBps);
    }

    /**
     * @notice `split()`, then push the gauge's share on into the internal bribe.
     * @dev The gauge claim is best-effort: a revert there (e.g. a paused bribe) must not block the
     *      split itself, which has already moved the tokens to their final owners. Skipped when the
     *      primary share did not go to a gauge.
     */
    function splitAndClaim()
        external
        returns (uint256 primary0, uint256 secondary0, uint256 primary1, uint256 secondary1)
    {
        address _gauge = gauge();
        bool primaryIsGauge = primaryRecipientOverride == address(0) && _gauge != address(0);

        (primary0, secondary0, primary1, secondary1) = split();

        if (primaryIsGauge) {
            try IHydrexGauge(_gauge).claimFees() returns (uint256 claimed0, uint256 claimed1) {
                emit GaugeFeesClaimed(_gauge, claimed0, claimed1);
            } catch {
                emit GaugeFeesClaimFailed(_gauge);
            }
        }
    }

    function _splitToken(
        address token,
        address _primary,
        address _secondary,
        uint16 shareBps
    ) internal returns (uint256 primaryAmount, uint256 secondaryAmount) {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance == 0) return (0, 0);
        if (_primary == address(0)) revert NoPrimaryRecipient();

        secondaryAmount = (balance * shareBps) / BPS_DENOMINATOR;
        primaryAmount = balance - secondaryAmount;

        if (secondaryAmount != 0) IERC20(token).safeTransfer(_secondary, secondaryAmount);
        if (primaryAmount != 0) IERC20(token).safeTransfer(_primary, primaryAmount);

        emit Split(token, _primary, primaryAmount, _secondary, secondaryAmount);
    }

    /* -----------------------------------------------------------------------
                                   ADMIN & CONFIG
    ----------------------------------------------------------------------- */

    /// @notice Override the primary recipient. Zero restores the default (the pool's gauge).
    function setPrimaryRecipientOverride(address recipient) external onlyFactoryOwner {
        emit PrimaryRecipientOverrideSet(primaryRecipientOverride, recipient);
        primaryRecipientOverride = recipient;
    }

    /// @notice Override the secondary recipient. Zero restores the factory default.
    function setSecondaryRecipientOverride(address recipient) external onlyFactoryOwner {
        emit SecondaryRecipientOverrideSet(secondaryRecipientOverride, recipient);
        secondaryRecipientOverride = recipient;
    }

    /// @notice Override the secondary share. Zero restores the factory default.
    function setSecondaryShareOverride(uint16 shareBps) external onlyFactoryOwner {
        if (shareBps > MAX_SECONDARY_SHARE_BPS) revert ShareTooHigh();
        emit SecondaryShareOverrideSet(secondaryShareBpsOverride, shareBps);
        secondaryShareBpsOverride = shareBps;
    }

    /// @notice Drop every override and fall back entirely to the factory defaults
    function clearOverrides() external onlyFactoryOwner {
        emit PrimaryRecipientOverrideSet(primaryRecipientOverride, address(0));
        emit SecondaryRecipientOverrideSet(secondaryRecipientOverride, address(0));
        emit SecondaryShareOverrideSet(secondaryShareBpsOverride, 0);
        primaryRecipientOverride = address(0);
        secondaryRecipientOverride = address(0);
        secondaryShareBpsOverride = 0;
    }

    /**
     * @notice Recover a token sent here that `split()` does not handle.
     * @dev `split()` only ever moves `token0`/`token1`; anything else airdropped here would be
     *      stuck otherwise. Also covers unwinding a splitter that has been retired.
     */
    function rescue(address token, address to) external onlyFactoryOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue();
        IERC20(token).safeTransfer(to, amount);
        emit Rescued(token, to, amount);
    }

    /**
     * @notice Recover native ETH sent here.
     * @dev There is no `receive()`, so ETH cannot arrive through a normal transfer — only by
     *      being force-sent (selfdestruct, or this address being named as a block/withdrawal
     *      recipient). That is rare but unrecoverable without this, so it exists as a backstop.
     */
    function rescueNative(address to) external onlyFactoryOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = address(this).balance;
        if (amount == 0) revert NothingToRescue();

        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();

        emit NativeRescued(to, amount);
    }
}
