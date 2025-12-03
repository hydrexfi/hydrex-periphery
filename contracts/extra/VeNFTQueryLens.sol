// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IERC721Enumerable {
    function tokenByIndex(uint256 index) external view returns (uint256);
}

interface IVeNFT {
    function totalNftsMinted() external view returns (uint256);
}

contract VeNFTQueryLens {
    function getHighestValidIndex(address veNFT) external view returns (uint256) {
        uint256 totalMinted = IVeNFT(veNFT).totalNftsMinted();
        
        if (totalMinted == 0) return 0;
        
        uint256 index = totalMinted - 1;
        
        while (index > 0) {
            try IERC721Enumerable(veNFT).tokenByIndex(index) returns (uint256) {
                return index;
            } catch {
                index--;
            }
        }
        
        try IERC721Enumerable(veNFT).tokenByIndex(0) returns (uint256) {
            return 0;
        } catch {
            return 0;
        }
    }
}

