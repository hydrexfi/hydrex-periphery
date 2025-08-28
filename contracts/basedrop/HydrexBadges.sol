// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Burnable} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Burnable.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";

/*
    __  __          __                 _____ 
   / / / /_  ______/ /_______  _  __  / __(_)
  / /_/ / / / / __  / ___/ _ \| |/_/ / /_/ / 
 / __  / /_/ / /_/ / /  /  __/>  <_ / __/ /  
/_/ /_/\__, /\__,_/_/   \___/_/|_(_)_/ /_/   
      /____/                                 

*/

/**
 * @title HydrexBadges
 * @notice Non-transferable ERC1155 badges for the Hydrex protocol
 * @dev Extends ERC1155 with role-based access control and non-transferable functionality
 */
contract HydrexBadges is ERC1155, AccessControl, ERC1155Burnable, ERC1155Supply {
    /// @notice Role identifier for addresses authorized to mint badges
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    /// @notice Whether badges are limited to a single copy per account
    bool public limitToSingleBadge = true;

    /// @notice Maximum supply for each badge ID (0 = unlimited)
    mapping(uint256 => uint256) public maxSupply;

    /// @notice Event emitted when max supply is configured for a badge
    event MaxSupplySet(uint256 indexed id, uint256 maxSupply);

    /**
     * @notice Constructor for HydrexBadges
     * @dev Sets up roles and grants appropriate roles to specified addresses
     */
    constructor() ERC1155("https://api.hydrex.fi/badges/") {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);
    }

    /**
     * @notice Set the URI for token metadata
     * @param newuri The new URI to set
     * @dev Only callable by addresses with DEFAULT_ADMIN_ROLE
     */
    function setURI(string memory newuri) public onlyRole(DEFAULT_ADMIN_ROLE) {
        _setURI(newuri);
    }

    /**
     * @notice Toggle whether badges are limited to single copies per account
     * @param _limit Whether to limit badges to single copies
     * @dev Only callable by addresses with DEFAULT_ADMIN_ROLE
     */
    function setLimitToSingleBadge(bool _limit) public onlyRole(DEFAULT_ADMIN_ROLE) {
        limitToSingleBadge = _limit;
    }

    /**
     * @notice Set maximum supply for a specific badge ID
     * @param id The badge ID to configure
     * @param _maxSupply Maximum supply (0 = unlimited)
     * @dev Only callable by addresses with DEFAULT_ADMIN_ROLE
     */
    function setMaxSupply(uint256 id, uint256 _maxSupply) public onlyRole(DEFAULT_ADMIN_ROLE) {
        maxSupply[id] = _maxSupply;
        emit MaxSupplySet(id, _maxSupply);
    }

    /**
     * @notice Set maximum supply for multiple badge IDs in a single transaction
     * @param ids Array of badge IDs to configure
     * @param _maxSupplies Array of maximum supplies (0 = unlimited)
     * @dev Only callable by addresses with DEFAULT_ADMIN_ROLE
     */
    function setMaxSupplyBatch(
        uint256[] memory ids, 
        uint256[] memory _maxSupplies
    ) public onlyRole(DEFAULT_ADMIN_ROLE) {
        require(ids.length == _maxSupplies.length, "Arrays length mismatch");
        
        for (uint256 i = 0; i < ids.length; i++) {
            maxSupply[ids[i]] = _maxSupplies[i];
            emit MaxSupplySet(ids[i], _maxSupplies[i]);
        }
    }

    /**
     * @notice Get maximum supply for a badge ID
     * @param id The badge ID to check
     * @return Maximum supply (0 = unlimited)
     */
    function getMaxSupply(uint256 id) public view returns (uint256) {
        return maxSupply[id];
    }

    /**
     * @notice Check if a badge ID has reached its maximum supply
     * @param id The badge ID to check
     * @return Whether the badge has reached max supply
     */
    function isMaxSupplyReached(uint256 id) public view returns (bool) {
        uint256 max = maxSupply[id];
        return max > 0 && totalSupply(id) >= max;
    }

    /**
     * @notice Mint a badge to a specified address
     * @param account The address to mint the badge to
     * @param id The token ID to mint
     * @param amount The amount of tokens to mint
     * @param data Additional data to pass to the mint function
     * @dev Only callable by addresses with MINTER_ROLE
     */
    function mint(address account, uint256 id, uint256 amount, bytes memory data) public onlyRole(MINTER_ROLE) {
        _mint(account, id, amount, data);
    }

    /**
     * @notice Mint multiple badges to a specified address
     * @param to The address to mint badges to
     * @param ids Array of token IDs to mint
     * @param amounts Array of amounts to mint for each token ID
     * @param data Additional data to pass to the mint function
     * @dev Only callable by addresses with MINTER_ROLE
     */
    function mintBatch(
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) public onlyRole(MINTER_ROLE) {
        _mintBatch(to, ids, amounts, data);
    }

    /**
     * @notice Override _update to make badges non-transferable and enforce single badge limit
     * @dev Allows minting (from=0) and burning (to=0) but blocks all transfers
     */
    function _update(
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory values
    ) internal override(ERC1155, ERC1155Supply) {
        // Allow minting (from == address(0)) and burning (to == address(0))
        if (from != address(0) && to != address(0)) {
            revert("HydrexBadges are non-transferable");
        }

        // Check constraints when minting
        if (from == address(0) && to != address(0)) {
            for (uint256 i = 0; i < ids.length; i++) {
                uint256 tokenId = ids[i];
                uint256 cumulativeAmount = values[i];

                // Check for duplicates of this token ID earlier in the arrays
                for (uint256 j = 0; j < i; j++) {
                    if (ids[j] == tokenId) {
                        cumulativeAmount += values[j];
                    }
                }

                // Check single badge limit
                if (limitToSingleBadge && balanceOf(to, tokenId) + cumulativeAmount > 1) {
                    revert("Badge limit exceeded: only one badge per account allowed");
                }

                // Check maximum supply limit
                uint256 max = maxSupply[tokenId];
                if (max > 0 && totalSupply(tokenId) + cumulativeAmount > max) {
                    revert("Maximum supply exceeded for badge ID");
                }
            }
        }

        super._update(from, to, ids, values);
    }

    /**
     * @notice Check if contract supports a given interface
     * @param interfaceId The interface identifier to check
     * @return bool Whether the interface is supported
     */
    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
