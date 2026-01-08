// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract HydrexDCAProxy is TransparentUpgradeableProxy {
    /// @dev Prevent bytecode collisions
    string public constant NAME = "HydrexDCAProxy";

    constructor(
        address logic_,
        address admin_,
        bytes memory data_
    ) TransparentUpgradeableProxy(logic_, admin_, data_) {}
}
