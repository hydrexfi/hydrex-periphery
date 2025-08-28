// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/*
    __  __          __                 _____ 
   / / / /_  ______/ /_______  _  __  / __(_)
  / /_/ / / / / __  / ___/ _ \| |/_/ / /_/ / 
 / __  / /_/ / /_/ / /  /  __/>  <_ / __/ /  
/_/ /_/\__, /\__,_/_/   \___/_/|_(_)_/ /_/   
      /____/                                 

*/

/**
 * @title Hydropoints
 * @notice Non-transferable ERC20 token given out in the protocol mining campaign
 * @dev Extends ERC20 and ERC20Burnable with role-based access control
 */
contract Hydropoints is ERC20, ERC20Burnable, AccessControl {
    /// @notice Role identifier for addresses authorized to mint tokens
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Role identifier for addresses authorized to redeem tokens
    bytes32 public constant REDEEMER_ROLE = keccak256("REDEEMER_ROLE");

    /**
     * @notice Constructor for Hydropoints
     * @param defaultAdmin The address that will have admin privileges
     * @dev Sets up roles and grants DEFAULT_ADMIN_ROLE to the specified address
     */
    constructor(address defaultAdmin) ERC20("Hydropoints", "HYDRO") {
        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
    }

    /**
     * @notice Mint tokens to a specified address
     * @param to The address to mint tokens to
     * @param amount The amount of tokens to mint
     * @dev Only callable by addresses with MINTER_ROLE
     */
    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    /**
     * @notice Redeem (burn) tokens from a specified address
     * @param from The address to redeem tokens from
     * @param amount The amount of tokens to redeem
     * @dev Only callable by addresses with REDEEMER_ROLE
     */
    function redeem(address from, uint256 amount) external onlyRole(REDEEMER_ROLE) {
        _burn(from, amount);
    }

    /**
     * @notice Override _update to make tokens non-transferable
     * @dev Allows minting (from=0) and burning (to=0) but blocks all transfers
     */
    function _update(address from, address to, uint256 value) internal override {
        // Allow minting (from == address(0)) and burning (to == address(0))
        if (from != address(0) && to != address(0)) {
            revert("Hydropoints are non-transferable");
        }
        super._update(from, to, value);
    }
}
