// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Hydropoints} from "./Hydropoints.sol";
import {IHydrexVotingEscrow} from "../interfaces/IHydrexVotingEscrow.sol";

/*
    __  __          __                 _____ 
   / / / /_  ______/ /_______  _  __  / __(_)
  / /_/ / / / / __  / ___/ _ \| |/_/ / /_/ / 
 / __  / /_/ / /_/ / /  /  __/>  <_ / __/ /  
/_/ /_/\__, /\__,_/_/   \___/_/|_(_)_/ /_/   
      /____/                                 

*/

/**
 * @title BasedropCheckout
 * @notice Contract for converting hydropoints & badges to HYDX token locks
 */
contract BasedropCheckout is AccessControl, ReentrancyGuard {
    /// @notice HYDX token contract
    IERC20 public immutable hydrexToken;

    /// @notice Hydropoints token contract
    Hydropoints public immutable hydropointsToken;

    /// @notice USDC token contract
    IERC20 public immutable usdc;

    /// @notice Hydrex voting escrow contract for creating locks
    IHydrexVotingEscrow public immutable votingEscrow;

    /// @notice Conversion rate: hydropoints per HYDX (10:1)
    uint256 public constant CONVERSION_RATE = 10;

    /// @notice USDC conversion rate: 10 hydropoints = 0.01 USDC for temporary locks
    uint256 public constant USDC_CONVERSION_RATE = 10000;

    /// @notice Lock duration (0 for permanent lock)
    uint256 public constant LOCK_DURATION = 0;

    /// @notice Lock type for temporary lock
    uint8 public constant LOCK_TYPE_TEMPORARY = 1;

    /// @notice Lock type for permanent lock
    uint8 public constant LOCK_TYPE_PERMANENT = 2;

    /// @notice Mapping from address to their veHYDX badge allocation amount
    mapping(address => uint256) public veHydxFromBadges;

    /// @notice Mapping to track if an address has claimed their badge allocation
    mapping(address => bool) public badgeAllocationClaimed;

    event HydropointsRedeemed(
        address indexed user,
        uint256 hydropointsRedeemed,
        uint256 hydrexLocked,
        bool isPermalock
    );
    event BadgeAllocationClaimed(address indexed user, uint256 hydrexAmount);

    /**
     * @notice Constructor for BasedropCheckout
     * @param _hydrexToken Address of the HYDX token contract
     * @param _hydropointsToken Address of the hydropoints token contract
     * @param _usdc Address of the USDC token contract
     * @param _votingEscrow Address of the voting escrow contract
     * @param _defaultAdmin Address that will have admin privileges
     */
    constructor(
        address _hydrexToken,
        address _hydropointsToken,
        address _usdc,
        address _votingEscrow,
        address _defaultAdmin
    ) {
        require(_hydrexToken != address(0), "Invalid HYDX token address");
        require(_hydropointsToken != address(0), "Invalid hydropoints token address");
        require(_usdc != address(0), "Invalid USDC token address");
        require(_votingEscrow != address(0), "Invalid voting escrow address");
        require(_defaultAdmin != address(0), "Invalid admin address");

        hydrexToken = IERC20(_hydrexToken);
        hydropointsToken = Hydropoints(_hydropointsToken);
        usdc = IERC20(_usdc);
        votingEscrow = IHydrexVotingEscrow(_votingEscrow);

        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
    }

    /*
       View functions
    */

    /**
     * @notice Calculate HYDX equivalent for given hydropoints
     * @param hydropointsAmount Amount of hydropoints
     * @return HYDX equivalent amount
     */
    function calculateHydrexEquivalent(uint256 hydropointsAmount) public pure returns (uint256) {
        return hydropointsAmount / CONVERSION_RATE;
    }

    /**
     * @notice Calculate USDC amount required for given hydropoints
     * @param hydropointsAmount Amount of hydropoints
     * @return USDC amount required (in 6 decimals)
     */
    function calculateUsdcRequired(uint256 hydropointsAmount) public pure returns (uint256) {
        return (hydropointsAmount * USDC_CONVERSION_RATE) / (10 * 1e18);
    }

    /**
     * @notice Get badge allocation amount for a specific address
     * @param user Address to check allocation for
     * @return Badge allocation amount in HYDX tokens
     */
    function getBadgeAllocation(address user) external view returns (uint256) {
        return veHydxFromBadges[user];
    }

    /**
     * @notice Check if a user has claimed their badge allocation
     * @param user Address to check claim status for
     * @return True if allocation has been claimed, false otherwise
     */
    function hasClaimed(address user) external view returns (bool) {
        return badgeAllocationClaimed[user];
    }

    /**
     * @notice Check if a user can claim their badge allocation
     * @param user Address to check
     * @return True if user can claim (has allocation and hasn't claimed yet)
     */
    function canClaim(address user) external view returns (bool) {
        return veHydxFromBadges[user] > 0 && !badgeAllocationClaimed[user];
    }

    /*
       User functions
    */

    /**
     * @notice Create a lock by redeeming hydropoints
     * @param hydropointsAmount Amount of hydropoints to redeem
     * @param isPermalock Whether to create a permanent lock (true) or temporary lock (false)
     * @dev User must approve this contract to spend their hydropoints and USDC (if temporary lock)
     */
    function redeemHydropoints(uint256 hydropointsAmount, bool isPermalock) external nonReentrant {
        require(hydropointsAmount > 0, "Amount must be greater than 0");

        uint256 hydrexAmount = calculateHydrexEquivalent(hydropointsAmount);
        require(hydrexAmount > 0, "Insufficient hydropoints for minimum lock");

        uint8 lockType = isPermalock ? LOCK_TYPE_PERMANENT : LOCK_TYPE_TEMPORARY;
        if (!isPermalock) {
            uint256 usdcRequired = calculateUsdcRequired(hydropointsAmount);
            require(usdc.transferFrom(msg.sender, address(this), usdcRequired), "USDC transfer failed");
        }

        hydropointsToken.redeem(msg.sender, hydropointsAmount);
        hydrexToken.approve(address(votingEscrow), hydrexAmount);
        votingEscrow.createLockFor(hydrexAmount, LOCK_DURATION, msg.sender, lockType);

        emit HydropointsRedeemed(msg.sender, hydropointsAmount, hydrexAmount, isPermalock);
    }

    /**
     * @notice Claim badge allocation and create a permanent lock
     * @dev Creates a permanent lock for the caller's badge allocation amount
     */
    function claimBadgeAllocation() external nonReentrant {
        uint256 allocation = veHydxFromBadges[msg.sender];
        require(allocation > 0, "No badge allocation available");
        require(!badgeAllocationClaimed[msg.sender], "Badge allocation already claimed");

        badgeAllocationClaimed[msg.sender] = true;
        hydrexToken.approve(address(votingEscrow), allocation);
        votingEscrow.createLockFor(allocation, LOCK_DURATION, msg.sender, LOCK_TYPE_PERMANENT);

        emit BadgeAllocationClaimed(msg.sender, allocation);
    }

    /* 
        Admin functions
    */

    /**
     * @notice Set badge allocations for multiple users (admin only)
     * @param users Array of addresses to set allocations for
     * @param amounts Array of HYDX token allocation amounts
     * @dev Only callable by addresses with DEFAULT_ADMIN_ROLE
     */
    function setBadgeAllocations(
        address[] calldata users,
        uint256[] calldata amounts
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(users.length == amounts.length, "Arrays length mismatch");

        for (uint256 i = 0; i < users.length; i++) {
            require(users[i] != address(0), "Invalid user address");
            veHydxFromBadges[users[i]] = amounts[i];
        }
    }

    /**
     * @notice Withdraw any ERC20 tokens from contract (admin only)
     * @param token Address of the token to withdraw
     * @param to Address to send tokens to
     * @param amount Amount of tokens to withdraw
     * @dev Only callable by addresses with DEFAULT_ADMIN_ROLE
     */
    function withdrawTokens(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(0), "Invalid token address");
        require(to != address(0), "Invalid recipient address");
        require(amount > 0, "Amount must be greater than 0");

        IERC20 tokenContract = IERC20(token);
        require(amount <= tokenContract.balanceOf(address(this)), "Insufficient balance");

        require(tokenContract.transfer(to, amount), "Token transfer failed");
    }
}
