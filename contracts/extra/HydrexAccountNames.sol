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

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/**
 * @title HydrexAccountNames
 * @notice Simple contract to let veToken holders name their tokens
 */
contract HydrexAccountNames {
    /// @notice Maximum length for account names
    uint256 public constant MAX_NAME_LENGTH = 24;
    
    /// @notice veNFT contract address
    address public immutable veToken;
    
    /// @notice Mapping from tokenId to account name
    mapping(uint256 => string) public names;

    /// @notice Emitted when a name is set for a tokenId
    event NameSet(uint256 indexed tokenId, string name, address indexed owner);

    /**
     * @param _veToken Address of the veNFT contract
     */
    constructor(address _veToken) {
        require(_veToken != address(0), "Invalid veToken address");
        veToken = _veToken;
    }

    /**
     * @notice Set a name for a tokenId (only owner can call)
     * @param tokenId The veNFT tokenId to name
     * @param name The name to set (max 24 characters)
     */
    function setName(uint256 tokenId, string calldata name) external {
        require(IERC721(veToken).ownerOf(tokenId) == msg.sender, "Not token owner");
        require(bytes(name).length <= MAX_NAME_LENGTH, "Name too long");
        names[tokenId] = name;
        emit NameSet(tokenId, name, msg.sender);
    }

    /**
     * @notice Get the name for a tokenId
     * @param tokenId The veNFT tokenId
     * @return The name associated with the tokenId
     */
    function getName(uint256 tokenId) external view returns (string memory) {
        return names[tokenId];
    }
    
    /**
     * @notice Get names for multiple tokenIds
     * @param tokenIds Array of veNFT tokenIds
     * @return Array of names corresponding to the tokenIds
     */
    function getBulkNames(uint256[] calldata tokenIds) external view returns (string[] memory) {
        string[] memory result = new string[](tokenIds.length);
        for (uint256 i = 0; i < tokenIds.length; i++) {
            result[i] = names[tokenIds[i]];
        }
        return result;
    }
}
