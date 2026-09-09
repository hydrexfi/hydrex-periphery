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

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {HydrexFeeSplitter} from "./HydrexFeeSplitter.sol";
import {IAlgebraPool, IHydrexVoter} from "./interfaces/IFeeSplitterExternal.sol";

/**
 * @title HydrexFeeSplitterFactory
 * @notice Deploys one HydrexFeeSplitter per Algebra pool, tracks them, and runs them in batches.
 *         Also holds the defaults every splitter inherits.
 */
contract HydrexFeeSplitterFactory is Ownable2Step {
    /* -----------------------------------------------------------------------
                                    DECLARATIONS
    ----------------------------------------------------------------------- */

    /// @notice Upper bound on the secondary share; mirrors the splitter's own cap
    uint16 public constant MAX_SECONDARY_SHARE_BPS = 2_000; // 20%

    /// @notice Hydrex voter, used by splitters to resolve their pool's current gauge
    address public immutable voter;

    /// @notice Algebra factory every managed pool must belong to
    address public immutable algebraFactory;

    /// @notice Default secondary (Algebra) recipient inherited by splitters without an override
    address public defaultSecondaryRecipient;

    /// @notice Default secondary (Algebra) share in bps inherited by splitters without an override
    uint16 public defaultSecondaryShareBps;

    /// @notice Primary recipient used by a splitter whose pool has no gauge. Zero holds the fees.
    address public fallbackPrimaryRecipient;

    /// @notice Splitter for a pool. Zero when none has been deployed.
    mapping(address => address) public splitterForPool;

    /// @notice Pool a splitter serves. Zero for unknown splitters.
    mapping(address => address) public poolForSplitter;

    /// @notice Every splitter deployed by this factory
    mapping(address => bool) public isSplitter;

    /// @notice Splitters, in deployment order
    address[] public splitters;

    event SplitterCreated(address indexed splitter, address indexed pool);
    event DefaultSecondaryRecipientSet(address indexed previous, address indexed current);
    event DefaultSecondaryShareBpsSet(uint16 previous, uint16 current);
    event FallbackPrimaryRecipientSet(address indexed previous, address indexed current);
    event SplitFailed(address indexed splitter);
    event NativeRescued(address indexed to, uint256 amount);

    error ZeroAddress();
    error ShareTooHigh();
    error SplitterExists(address pool, address splitter);
    error NotASplitter(address splitter);
    error NotAnAlgebraPool(address pool);
    error EmptyInput();
    error NothingToRescue();
    error NativeTransferFailed();

    /**
     * @param _voter Hydrex voter, used to resolve each pool's gauge
     * @param _algebraFactory Algebra factory every managed pool must report as its `factory()`
     * @param _defaultSecondaryRecipient Algebra fee receiver inherited by every splitter
     * @param _defaultSecondaryShareBps Algebra share in bps, e.g. 150 for 1.5%
     * @param _fallbackPrimaryRecipient Recipient of the primary share while a pool has no gauge
     */
    constructor(
        address _voter,
        address _algebraFactory,
        address _defaultSecondaryRecipient,
        uint16 _defaultSecondaryShareBps,
        address _fallbackPrimaryRecipient
    ) Ownable(msg.sender) {
        if (_voter == address(0)) revert ZeroAddress();
        if (_algebraFactory == address(0)) revert ZeroAddress();
        if (_defaultSecondaryRecipient == address(0)) revert ZeroAddress();
        if (_fallbackPrimaryRecipient == address(0)) revert ZeroAddress();
        if (_defaultSecondaryShareBps > MAX_SECONDARY_SHARE_BPS) revert ShareTooHigh();

        voter = _voter;
        algebraFactory = _algebraFactory;
        defaultSecondaryRecipient = _defaultSecondaryRecipient;
        defaultSecondaryShareBps = _defaultSecondaryShareBps;
        fallbackPrimaryRecipient = _fallbackPrimaryRecipient;

        emit DefaultSecondaryRecipientSet(address(0), _defaultSecondaryRecipient);
        emit DefaultSecondaryShareBpsSet(0, _defaultSecondaryShareBps);
        emit FallbackPrimaryRecipientSet(address(0), _fallbackPrimaryRecipient);
    }

    /* -----------------------------------------------------------------------
                                       VIEWS
    ----------------------------------------------------------------------- */

    /// @notice Config every splitter inherits unless it overrides it
    function defaults()
        external
        view
        returns (address secondaryRecipient, uint16 secondaryShareBps, address fallbackPrimary)
    {
        return (defaultSecondaryRecipient, defaultSecondaryShareBps, fallbackPrimaryRecipient);
    }

    /// @notice Address a pool's splitter will occupy, deployed or not
    function predictSplitter(address pool) public view returns (address) {
        bytes32 initCodeHash = keccak256(
            abi.encodePacked(type(HydrexFeeSplitter).creationCode, abi.encode(pool))
        );
        return Create2.computeAddress(keccak256(abi.encode(pool)), initCodeHash, address(this));
    }

    /// @notice Number of splitters deployed
    function splittersCount() external view returns (uint256) {
        return splitters.length;
    }

    /// @notice Every splitter
    function getSplitters() external view returns (address[] memory) {
        return splitters;
    }

    /// @notice A window of the registry, for reading a large fleet in pages
    /// @dev Deliberately not an overload of `getSplitters()`: an overloaded name forces off-chain
    ///      tooling to disambiguate by full signature.
    function getSplittersPaged(uint256 start, uint256 count) external view returns (address[] memory page) {
        uint256 end = _end(start, count, splitters.length);
        page = new address[](end > start ? end - start : 0);
        for (uint256 i = start; i < end; ++i) page[i - start] = splitters[i];
    }

    /// @notice Splitter for the pool behind `gauge`, or zero
    function splitterForGauge(address gauge) external view returns (address) {
        address pool = IHydrexVoter(voter).poolForGauge(gauge);
        if (pool == address(0)) return address(0);
        return splitterForPool[pool];
    }

    /**
     * @dev Requires a real Algebra Integral pool from the configured factory. Deliberately does
     *      not require a gauge: pools are often listed before they get one.
     */
    function _validatePool(address pool) internal view {
        if (pool == address(0)) revert ZeroAddress();
        // Solidity's extcodesize check runs in this frame, so a codeless address would revert
        // outside the try/catch below.
        if (pool.code.length == 0) revert NotAnAlgebraPool(pool);

        try IAlgebraPool(pool).factory() returns (address poolFactory) {
            if (poolFactory != algebraFactory) revert NotAnAlgebraPool(pool);
        } catch {
            revert NotAnAlgebraPool(pool);
        }

        // A pool without `communityVault()` can never push fees here.
        try IAlgebraPool(pool).communityVault() returns (address) {} catch {
            revert NotAnAlgebraPool(pool);
        }
    }

    function _end(uint256 start, uint256 count, uint256 total) internal pure returns (uint256 end) {
        if (start >= total) return start;
        end = start + count;
        if (end > total || end < start) end = total;
    }

    /* -----------------------------------------------------------------------
                                       WRITES
    ----------------------------------------------------------------------- */

    /**
     * @notice Deploy the splitter for an Algebra pool.
     * @dev Permissionless: the address is deterministic and the configuration is inherited from
     *      this factory, so an outside caller cannot produce a splitter that differs from the one
     *      the owner would have deployed. The pool needs no gauge — one deployed early simply
     *      routes to `fallbackPrimaryRecipient` until a gauge appears.
     */
    function createSplitter(address pool) external returns (address splitter) {
        splitter = splitterForPool[pool];
        if (splitter != address(0)) revert SplitterExists(pool, splitter);
        return _createSplitter(pool);
    }

    /**
     * @notice Deploy splitters for many pools, skipping any that already have one.
     * @dev Idempotent, so it is safe to re-run over the same list as new pools go live.
     * @return created Splitter per input pool; the existing one where already deployed
     * @return newlyCreated Whether each entry was deployed by this call
     */
    function createSplitters(
        address[] calldata pools
    ) external returns (address[] memory created, bool[] memory newlyCreated) {
        uint256 length = pools.length;
        if (length == 0) revert EmptyInput();

        created = new address[](length);
        newlyCreated = new bool[](length);

        for (uint256 i; i < length; ++i) {
            address existing = splitterForPool[pools[i]];
            if (existing != address(0)) {
                created[i] = existing;
            } else {
                created[i] = _createSplitter(pools[i]);
                newlyCreated[i] = true;
            }
        }
    }

    /**
     * @notice Split a specific list of this factory's splitters in one transaction.
     * @dev A failing splitter is skipped rather than reverting the batch, so one misbehaving token
     *      cannot block the rest of the fleet. At least one live Base pool holds a token whose
     *      `balanceOf` traps the EVM, so this is load-bearing, not defensive decoration.
     *
     *      Addresses this factory did not deploy are skipped. `splitMany` is permissionless, and a
     *      splitter grants this factory the same rights as its owner, so the factory must never be
     *      usable to call arbitrary code. Today the selector is fixed to `split()` and that alone
     *      would be safe, but the registry check keeps the invariant true regardless of what is
     *      added here later.
     * @return succeeded Number of splitters that split without reverting
     */
    function splitMany(address[] calldata targets) external returns (uint256 succeeded) {
        uint256 length = targets.length;
        if (length == 0) revert EmptyInput();

        for (uint256 i; i < length; ++i) {
            address splitter = targets[i];
            if (!isSplitter[splitter]) {
                emit SplitFailed(splitter);
                continue;
            }
            if (_trySplit(splitter)) {
                unchecked {
                    ++succeeded;
                }
            }
        }
    }

    /**
     * @notice Split a contiguous window of the registry.
     * @dev The keeper's default entry point. An empty splitter costs ~28k gas to skip, so sweeping
     *      the whole fleet blind is cheaper than querying which ones hold fees first.
     */
    function splitRange(uint256 start, uint256 count) external returns (uint256 succeeded) {
        uint256 end = _end(start, count, splitters.length);

        for (uint256 i = start; i < end; ++i) {
            if (_trySplit(splitters[i])) {
                unchecked {
                    ++succeeded;
                }
            }
        }
    }

    function _createSplitter(address pool) internal returns (address splitter) {
        _validatePool(pool);

        splitter = address(new HydrexFeeSplitter{salt: keccak256(abi.encode(pool))}(pool));

        splitterForPool[pool] = splitter;
        poolForSplitter[splitter] = pool;
        isSplitter[splitter] = true;
        splitters.push(splitter);

        emit SplitterCreated(splitter, pool);
    }

    function _trySplit(address splitter) internal returns (bool) {
        try HydrexFeeSplitter(splitter).split() returns (uint256, uint256, uint256, uint256) {
            return true;
        } catch {
            emit SplitFailed(splitter);
            return false;
        }
    }

    /* -----------------------------------------------------------------------
                                   ADMIN & CONFIG
    ----------------------------------------------------------------------- */

    /// @notice Retarget the Algebra share for every splitter that has not overridden it
    function setDefaultSecondaryRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        emit DefaultSecondaryRecipientSet(defaultSecondaryRecipient, recipient);
        defaultSecondaryRecipient = recipient;
    }

    /// @notice Reprice the Algebra share for every splitter that has not overridden it
    function setDefaultSecondaryShareBps(uint16 shareBps) external onlyOwner {
        if (shareBps > MAX_SECONDARY_SHARE_BPS) revert ShareTooHigh();
        emit DefaultSecondaryShareBpsSet(defaultSecondaryShareBps, shareBps);
        defaultSecondaryShareBps = shareBps;
    }

    /// @notice Set where the primary share goes for splitters whose pool has no gauge
    function setFallbackPrimaryRecipient(address recipient) external onlyOwner {
        emit FallbackPrimaryRecipientSet(fallbackPrimaryRecipient, recipient);
        fallbackPrimaryRecipient = recipient;
    }

    /// @notice Set the primary recipient override on many splitters. Zero restores the gauge.
    function setPrimaryRecipientOverrides(address[] calldata targets, address recipient) external onlyOwner {
        uint256 length = targets.length;
        if (length == 0) revert EmptyInput();
        for (uint256 i; i < length; ++i) {
            _requireSplitter(targets[i]);
            HydrexFeeSplitter(targets[i]).setPrimaryRecipientOverride(recipient);
        }
    }

    /// @notice Set the secondary recipient override on many splitters. Zero restores the default.
    function setSecondaryRecipientOverrides(address[] calldata targets, address recipient) external onlyOwner {
        uint256 length = targets.length;
        if (length == 0) revert EmptyInput();
        for (uint256 i; i < length; ++i) {
            _requireSplitter(targets[i]);
            HydrexFeeSplitter(targets[i]).setSecondaryRecipientOverride(recipient);
        }
    }

    /// @notice Set the secondary share override on many splitters. Zero restores the default.
    function setSecondaryShareOverrides(address[] calldata targets, uint16 shareBps) external onlyOwner {
        uint256 length = targets.length;
        if (length == 0) revert EmptyInput();
        for (uint256 i; i < length; ++i) {
            _requireSplitter(targets[i]);
            HydrexFeeSplitter(targets[i]).setSecondaryShareOverride(shareBps);
        }
    }

    /// @notice Drop every override on many splitters, returning them to the factory defaults
    function clearOverrides(address[] calldata targets) external onlyOwner {
        uint256 length = targets.length;
        if (length == 0) revert EmptyInput();
        for (uint256 i; i < length; ++i) {
            _requireSplitter(targets[i]);
            HydrexFeeSplitter(targets[i]).clearOverrides();
        }
    }

    /// @notice Recover a stray token from a splitter this factory deployed
    function rescueFromSplitter(
        address splitter,
        address token,
        address to
    ) external onlyOwner returns (uint256 amount) {
        _requireSplitter(splitter);
        return HydrexFeeSplitter(splitter).rescue(token, to);
    }

    /// @notice Recover native ETH force-sent to a splitter this factory deployed
    function rescueNativeFromSplitter(address splitter, address to) external onlyOwner returns (uint256 amount) {
        _requireSplitter(splitter);
        return HydrexFeeSplitter(splitter).rescueNative(to);
    }

    /**
     * @notice Recover native ETH force-sent to the factory itself.
     * @dev Like the splitter, the factory has no `receive()`, so ETH can only arrive by being
     *      force-sent. This exists so that it is not permanently stuck when it does.
     */
    function rescueNative(address to) external onlyOwner returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = address(this).balance;
        if (amount == 0) revert NothingToRescue();

        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();

        emit NativeRescued(to, amount);
    }

    function _requireSplitter(address splitter) internal view {
        if (!isSplitter[splitter]) revert NotASplitter(splitter);
    }
}
