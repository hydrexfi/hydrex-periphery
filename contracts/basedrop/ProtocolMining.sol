// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPair} from "../interfaces/IPair.sol";
import "./Hydropoints.sol";

/*
    __  __          __                 _____ 
   / / / /_  ______/ /_______  _  __  / __(_)
  / /_/ / / / / __  / ___/ _ \| |/_/ / /_/ / 
 / __  / /_/ / /_/ / /  /  __/>  <_ / __/ /  
/_/ /_/\__, /\__,_/_/   \___/_/|_(_)_/ /_/   
      /____/                                 

*/

contract ProtocolMining is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct UserInfo {
        uint256 amount; // How many tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 pendingReward; // Undistributed rewards.
    }

    struct PoolInfo {
        IERC20 stakeToken; // Address of stake token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. Reward to distribute per block.
        uint256 totalStaked; // Amount of tokens staked in given pool
        uint256 lastRewardTime; // Last timestamp rewards distribution occurs.
        uint256 accRewardPerShare; // Accumulated rewards per share, times 1e30. See below.
        uint16 depositFeeBP; // Deposit fee in basis points
    }

    Hydropoints public reward;
    uint256 public rewardPerSecond;
    address public feeAddress;
    uint256 public referralPercent = 15; // 15% of rewards go to referral

    mapping(address => address) public referrer;
    mapping(address => address[]) public referrals;
    mapping(IERC20 => bool) public poolExistence;
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    mapping(address => bool) public hasDeposited;

    uint256 public totalAllocPoint;
    uint256 public startTime;
    uint256 public endTime;
    bool public harvestEnable = false;
    uint256 public totalRewardsAllocated = 0;

    PoolInfo[] public poolInfo;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event SetFeeAddress(address indexed user, address indexed newAddress);
    event UpdateEmissionRate(address indexed user, uint256 rewardPerSecond);
    event SetStartTime(address indexed user, uint256 startTime);
    event SetEndTime(address indexed user, uint256 endTime);
    event ClaimFees(address indexed user, uint256 indexed pid, uint256 amount0, uint256 amount1);
    event HarvestEnabled(address indexed user);
    event ReferralSet(address indexed user, address indexed referral);
    event ReferralReward(address indexed referral, address indexed user, uint256 amount);
    event ReferralPercentUpdated(address indexed user, uint256 oldPercent, uint256 newPercent);
    event LogPoolAddition(uint256 indexed pid, uint256 allocPoint, IERC20 indexed stakeToken, uint16 depositFee);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint, uint16 depositFee);
    event LogUpdatePool(uint256 indexed pid, uint256 lastRewardTime, uint256 stakeSupply, uint256 accRewardPerShare);

    constructor(
        Hydropoints _reward,
        address _feeAddress,
        uint256 _rewardPerSecond,
        uint256 _startTime,
        uint256 _endTime
    ) Ownable(msg.sender) {
        reward = _reward;
        feeAddress = _feeAddress;
        rewardPerSecond = _rewardPerSecond;
        startTime = _startTime;
        endTime = _endTime;
    }

    modifier nonDuplicated(IERC20 _stakeToken) {
        require(poolExistence[_stakeToken] == false, "nonDuplicated: duplicated");
        _;
    }

    /************************************************************
     *                      VIEW FUNCTIONS                     *
     ************************************************************/

    function poolLength() external view returns (uint256) {
        return poolInfo.length;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to) public view returns (uint256) {
        if (_to <= endTime) {
            return _to - _from;
        } else if (_from >= endTime) {
            return 0;
        } else {
            return endTime - _from;
        }
    }

    // View function to see pending rewards on frontend.
    function pendingRewards(uint256 _pid, address _user) external view returns (uint256 pending) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accRewardPerShare = pool.accRewardPerShare;
        uint256 stakeSupply = pool.totalStaked;
        if (block.timestamp > pool.lastRewardTime && stakeSupply != 0) {
            uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
            uint256 tokenReward = (multiplier * rewardPerSecond * pool.allocPoint) / totalAllocPoint;
            accRewardPerShare = accRewardPerShare + ((tokenReward * 1e30) / stakeSupply);
        }
        pending = ((user.amount * accRewardPerShare) / 1e30 - user.rewardDebt) + user.pendingReward;
    }

    // View function to see pending referral rewards breakdown for a referrer
    function pendingReferralRewardsBreakdown(
        address _referrer,
        uint256 _startPid,
        uint256 _endPid
    ) external view returns (address[] memory addresses, uint256[] memory amounts) {
        require(_startPid <= _endPid, "Invalid pid range");
        require(_endPid < poolInfo.length, "End pid out of bounds");

        address[] memory userReferrals = referrals[_referrer];
        addresses = new address[](userReferrals.length);
        amounts = new uint256[](userReferrals.length);

        for (uint256 i = 0; i < userReferrals.length; i++) {
            address referredUser = userReferrals[i];
            addresses[i] = referredUser;

            uint256 userTotalReferralReward = 0;
            // Check specified pool range for this referred user's pending rewards
            for (uint256 pid = _startPid; pid <= _endPid; pid++) {
                uint256 userPending = this.pendingRewards(pid, referredUser);

                // Add referral portion to user's total
                if (userPending > 0) {
                    userTotalReferralReward += (userPending * referralPercent) / 100;
                }
            }
            amounts[i] = userTotalReferralReward;
        }
    }

    // View function to see total pending rewards for a user across specified pool range plus referral rewards
    function totalPendingRewards(
        address _user,
        uint256 _startPid,
        uint256 _endPid
    ) external view returns (uint256 total) {
        require(_startPid <= _endPid, "Invalid pid range");
        require(_endPid < poolInfo.length, "End pid out of bounds");

        // Sum up pending rewards from specified pool range
        for (uint256 pid = _startPid; pid <= _endPid; pid++) {
            total += this.pendingRewards(pid, _user);
        }

        // Add referral rewards if user is a referrer
        address[] memory userReferrals = referrals[_user];
        for (uint256 i = 0; i < userReferrals.length; i++) {
            address referredUser = userReferrals[i];
            // Check specified pool range for this referred user's pending rewards
            for (uint256 pid = _startPid; pid <= _endPid; pid++) {
                uint256 userPending = this.pendingRewards(pid, referredUser);
                if (userPending > 0) {
                    total += (userPending * referralPercent) / 100;
                }
            }
        }
    }

    /************************************************************
     *                      USER FUNCTIONS                     *
     ************************************************************/

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 stakeSupply = pool.totalStaked;
        if (stakeSupply == 0 || pool.allocPoint == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardTime, block.timestamp);
        uint256 totalRewards = (multiplier * rewardPerSecond * pool.allocPoint) / totalAllocPoint;
        if (totalRewards == 0) return;

        totalRewardsAllocated += totalRewards;

        pool.accRewardPerShare = pool.accRewardPerShare + ((totalRewards * 1e30) / stakeSupply);
        pool.lastRewardTime = block.timestamp;
        emit LogUpdatePool(_pid, pool.lastRewardTime, stakeSupply, pool.accRewardPerShare);
    }

    // Deposit tokens to PreMining for reward allocation.
    function deposit(uint256 _pid, uint256 _amount, address _referral) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 finalDepositAmount;

        // Set referral only on user's very first deposit to the protocol
        if (!hasDeposited[msg.sender]) {
            hasDeposited[msg.sender] = true;

            if (_referral != address(0) && _referral != msg.sender) {
                referrer[msg.sender] = _referral;
                referrals[_referral].push(msg.sender);
                emit ReferralSet(msg.sender, _referral);
            }
            // If no referral provided, referrer[msg.sender] stays address(0)
        }

        updatePool(_pid);
        if (user.amount > 0) {
            _harvest(_pid, msg.sender);
        }
        if (_amount > 0) {
            // Prefetch balance to account for transfer fees
            uint256 preStakeBalance = pool.stakeToken.balanceOf(address(this));
            pool.stakeToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            finalDepositAmount = pool.stakeToken.balanceOf(address(this)) - preStakeBalance;

            if (pool.depositFeeBP > 0) {
                uint256 depositFee = (finalDepositAmount * pool.depositFeeBP) / 10000;
                pool.stakeToken.safeTransfer(feeAddress, depositFee);
                finalDepositAmount = finalDepositAmount - depositFee;
            }
            user.amount = user.amount + finalDepositAmount;
            pool.totalStaked = pool.totalStaked + finalDepositAmount;
        }
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e30;
        emit Deposit(msg.sender, _pid, finalDepositAmount);
    }

    // Withdraw tokens from PreMining.
    function withdraw(uint256 _pid, uint256 _amount) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        updatePool(_pid);
        _harvest(_pid, msg.sender);
        if (_amount > 0) {
            user.amount = user.amount - _amount;
            pool.totalStaked = pool.totalStaked - _amount;
            pool.stakeToken.safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = (user.amount * pool.accRewardPerShare) / 1e30;
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function _harvest(uint _pid, address _user) internal {
        UserInfo storage user = userInfo[_pid][_user];
        uint256 userPendingReward = user.pendingReward;
        uint256 pending = ((user.amount * poolInfo[_pid].accRewardPerShare) / 1e30 - user.rewardDebt) +
            userPendingReward;
        if (harvestEnable) {
            if (pending > 0) {
                uint256 referralReward = 0;
                address referral = referrer[_user];

                // Calculate referral reward if referral exists
                if (referral != address(0)) {
                    referralReward = (pending * referralPercent) / 100;
                    emit ReferralReward(referral, _user, referralReward);
                }

                if (userPendingReward != 0) {
                    user.pendingReward = 0;
                }

                // Mint full rewards for user
                if (pending > 0) {
                    reward.mint(_user, pending);
                }

                // Mint additional referral rewards on top
                if (referralReward > 0) {
                    reward.mint(referral, referralReward);
                }
            }
        } else {
            user.pendingReward = pending;
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.pendingReward = 0;
        pool.totalStaked = pool.totalStaked - amount;
        pool.stakeToken.safeTransfer(address(msg.sender), amount);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    /************************************************************
     *                     ADMIN FUNCTIONS                     *
     ************************************************************/

    // Admin function to set referral (override)
    function setReferral(address _referredUser, address _referrer) external onlyOwner {
        require(_referredUser != _referrer, "User cannot refer themselves");

        // Remove from old referral's list if exists
        address oldReferral = referrer[_referredUser];
        if (oldReferral != address(0)) {
            address[] storage oldReferralList = referrals[oldReferral];
            for (uint i = 0; i < oldReferralList.length; i++) {
                if (oldReferralList[i] == _referredUser) {
                    oldReferralList[i] = oldReferralList[oldReferralList.length - 1];
                    oldReferralList.pop();
                    break;
                }
            }
        }

        // Set new referral
        referrer[_referredUser] = _referrer;
        if (_referrer != address(0)) {
            referrals[_referrer].push(_referredUser);
        }
        emit ReferralSet(_referredUser, _referrer);
    }

    /// @param _startTime The block to start mining
    /// @notice can only be changed if mining has not started already
    function setStartTime(uint256 _startTime) external onlyOwner {
        require(startTime > block.timestamp, "Mining started");
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            PoolInfo storage pool = poolInfo[pid];
            pool.lastRewardTime = _startTime;
        }
        startTime = _startTime;
        emit SetStartTime(msg.sender, _startTime);
    }

    /// @param _endTime The block to end mining
    /// @notice can only be changed for future endTime
    function setEndTime(uint256 _endTime) external onlyOwner {
        require(_endTime > endTime, "End Time cannot be before current one");
        endTime = _endTime;
        emit SetEndTime(msg.sender, _endTime);
    }

    /// @param _pid The block to end mining
    /// @notice can only be changed for future endTime
    function claimFees(uint256 _pid) external onlyOwner {
        PoolInfo memory pool = poolInfo[_pid];
        (uint256 amount0, uint256 amount1) = IPair(address(pool.stakeToken)).claimFees();
        address token0 = IPair(address(pool.stakeToken)).token0();
        address token1 = IPair(address(pool.stakeToken)).token1();
        if (amount0 > 0) {
            IERC20(token0).safeTransfer(feeAddress, amount0);
        }
        if (amount1 > 0) {
            IERC20(token1).safeTransfer(feeAddress, amount1);
        }
        emit ClaimFees(msg.sender, _pid, amount0, amount1);
    }

    function setFeeAddress(address _feeAddress) public {
        require(msg.sender == feeAddress, "setFeeAddress: FORBIDDEN");
        feeAddress = _feeAddress;
        emit SetFeeAddress(msg.sender, _feeAddress);
    }

    function _updateEmissionRate(uint256 _rewardPerSecond) internal {
        rewardPerSecond = _rewardPerSecond;
        emit UpdateEmissionRate(msg.sender, _rewardPerSecond);
    }

    function updateEmissionRate(uint256 _rewardPerSecond) public onlyOwner {
        _updateEmissionRate(_rewardPerSecond);
        massUpdatePools();
    }

    function enableHarvest() public onlyOwner {
        harvestEnable = true;
        emit HarvestEnabled(msg.sender);
    }

    function setReferralPercent(uint256 _referralPercent) public onlyOwner {
        require(_referralPercent <= 100, "Referral percent cannot exceed 100%");
        uint256 oldPercent = referralPercent;
        referralPercent = _referralPercent;
        emit ReferralPercentUpdated(msg.sender, oldPercent, _referralPercent);
    }

    // Add a new token to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _stakeToken,
        uint16 _depositFeeBP,
        bool _withUpdate
    ) public onlyOwner nonDuplicated(_stakeToken) {
        require(_depositFeeBP <= 1000, "add: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        }

        uint256 lastRewardTime = block.timestamp > startTime ? block.timestamp : startTime;
        totalAllocPoint = totalAllocPoint + _allocPoint;
        poolExistence[_stakeToken] = true;

        poolInfo.push(
            PoolInfo({
                stakeToken: _stakeToken,
                allocPoint: _allocPoint,
                lastRewardTime: lastRewardTime,
                accRewardPerShare: 0,
                totalStaked: 0,
                depositFeeBP: _depositFeeBP
            })
        );

        emit LogPoolAddition(poolInfo.length - 1, _allocPoint, _stakeToken, _depositFeeBP);
    }

    // Update the given pool's allocation point and deposit fee. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint, uint16 _depositFeeBP, bool _withUpdate) public onlyOwner {
        require(_depositFeeBP <= 1000, "set: invalid deposit fee basis points");
        if (_withUpdate) {
            massUpdatePools();
        } else {
            updatePool(_pid);
        }

        totalAllocPoint = totalAllocPoint - poolInfo[_pid].allocPoint + _allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        poolInfo[_pid].depositFeeBP = _depositFeeBP;

        emit LogSetPool(_pid, _allocPoint, _depositFeeBP);
    }
}
