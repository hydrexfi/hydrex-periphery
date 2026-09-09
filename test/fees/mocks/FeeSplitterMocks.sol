// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name, string memory symbol, uint8 decimals_) ERC20(name, symbol) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Reverts on transfer, used to prove batch splitting tolerates a bad token.
contract MockBrokenToken is ERC20 {
    constructor() ERC20("Broken", "BRK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address, uint256) public pure override returns (bool) {
        revert("broken");
    }
}

contract MockAlgebraPool {
    address public token0;
    address public token1;
    address public factory;
    address public communityVault;
    uint128 public pending0;
    uint128 public pending1;

    constructor(address _token0, address _token1, address _factory) {
        token0 = _token0;
        token1 = _token1;
        factory = _factory;
    }

    function setCommunityVault(address vault) external {
        communityVault = vault;
    }

    function setPending(uint128 _pending0, uint128 _pending1) external {
        pending0 = _pending0;
        pending1 = _pending1;
    }

    function getCommunityFeePending() external view returns (uint128, uint128) {
        return (pending0, pending1);
    }

    /// @dev Mimics the pool flushing accumulated community fees to its vault.
    function pushFees(uint256 amount0, uint256 amount1) external {
        if (amount0 > 0) MockToken(token0).mint(communityVault, amount0);
        if (amount1 > 0) MockToken(token1).mint(communityVault, amount1);
    }
}

/// @dev A pool-shaped contract with no `communityVault()`, i.e. not Algebra Integral.
contract MockNonAlgebraPool {
    address public token0;
    address public token1;
    address public factory;

    constructor(address _token0, address _token1, address _factory) {
        token0 = _token0;
        token1 = _token1;
        factory = _factory;
    }
}

contract MockGauge {
    address public stakeToken;
    address public internalBribe;
    bool public claimReverts;
    uint256 public claimCount;

    constructor(address _stakeToken, address _internalBribe) {
        stakeToken = _stakeToken;
        internalBribe = _internalBribe;
    }

    function setClaimReverts(bool value) external {
        claimReverts = value;
    }

    /// @dev Mirrors GaugeIncentiveCampaign: sweeps the whole token0/token1 balance to the bribe.
    function claimFees() external returns (uint256 claimed0, uint256 claimed1) {
        require(!claimReverts, "claim reverts");
        claimCount++;

        address token0 = MockAlgebraPool(stakeToken).token0();
        address token1 = MockAlgebraPool(stakeToken).token1();

        claimed0 = IERC20(token0).balanceOf(address(this));
        claimed1 = IERC20(token1).balanceOf(address(this));
        if (claimed0 > 0) IERC20(token0).transfer(internalBribe, claimed0);
        if (claimed1 > 0) IERC20(token1).transfer(internalBribe, claimed1);
    }
}

contract MockVoter {
    address[] public poolList;
    mapping(address => address) public gauges;
    mapping(address => address) public poolForGauge;
    mapping(address => bool) public isGauge;
    mapping(address => bool) public isAlive;

    function length() external view returns (uint256) {
        return poolList.length;
    }

    function pools(uint256 index) external view returns (address) {
        return poolList[index];
    }

    function registerGauge(address pool, address gauge) external {
        poolList.push(pool);
        gauges[pool] = gauge;
        poolForGauge[gauge] = pool;
        isGauge[gauge] = true;
        isAlive[gauge] = true;
    }

    /// @dev Registers a pool with no gauge, as the real voter does for unincentivised pools.
    function registerPoolWithoutGauge(address pool) external {
        poolList.push(pool);
    }

    function setPoolForGauge(address gauge, address pool) external {
        poolForGauge[gauge] = pool;
    }

    /// @dev Detaches the gauge from a pool, as happens when a gauge is killed or replaced.
    function clearGauge(address pool) external {
        address gauge = gauges[pool];
        gauges[pool] = address(0);
        poolForGauge[gauge] = address(0);
        isGauge[gauge] = false;
        isAlive[gauge] = false;
    }

    function setGauge(address pool, address gauge) external {
        gauges[pool] = gauge;
        poolForGauge[gauge] = pool;
        isGauge[gauge] = true;
        isAlive[gauge] = true;
    }
}
