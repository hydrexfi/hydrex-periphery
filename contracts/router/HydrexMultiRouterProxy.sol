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

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title HydrexMultiRouterProxy
 * @notice UUPS-compatible ERC1967 proxy for HydrexMultiRouter
 */
contract HydrexMultiRouterProxy is ERC1967Proxy {
    /**
     * @notice Initialize the proxy with the implementation address and initialization data
     * @param logic_ Address of the initial implementation contract
     * @param data_ Encoded initialization call data
     */
    constructor(
        address logic_,
        bytes memory data_
    ) ERC1967Proxy(logic_, data_) {}
}
