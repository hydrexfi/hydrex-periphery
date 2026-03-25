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

/**
 * @title HydrexReceiver
 * @notice Minimal contract to receive bridged tokens + calldata from Solana via the
 *         Base-Solana bridge. Used as a smoke test to prove the bridge + calldata pipe
 *         works before building the full intent/escrow system.
 *
 * @dev The bridge executes calls from the sender's deterministic Twin contract on Base.
 *      This contract just logs what it receives for verification.
 *
 *      Call flow:
 *        1. Bridge mints wrapped tokens to Twin
 *        2. Bridge executes attached calldata FROM Twin
 *        3. Twin calls deliver() / ping() on this contract
 */
contract HydrexReceiver {
    address public immutable owner;
    address public immutable bridge;

    struct BridgeDelivery {
        address twinSender;
        address token;
        uint256 amount;
        bytes32 intentId;
        address usdcRecipient;
        uint256 timestamp;
    }

    BridgeDelivery[] public deliveries;

    event Delivered(
        uint256 indexed deliveryId,
        address indexed twinSender,
        address token,
        uint256 amount,
        bytes32 intentId,
        address usdcRecipient
    );

    event TokensReceived(
        address indexed from,
        address indexed token,
        uint256 amount
    );

    error Unauthorized();

    constructor(address _bridge) {
        owner = msg.sender;
        bridge = _bridge;
    }

    /**
     * @notice Called by the bridge (via Twin) to deliver bridged tokens + settlement data.
     * @dev In production this would verify the Twin is a registered solver and trigger
     *      escrow settlement. For this test we just log everything.
     */
    function deliver(
        address token,
        uint256 amount,
        bytes32 intentId,
        address usdcRecipient
    ) external {
        BridgeDelivery memory d = BridgeDelivery({
            twinSender: msg.sender,
            token: token,
            amount: amount,
            intentId: intentId,
            usdcRecipient: usdcRecipient,
            timestamp: block.timestamp
        });

        deliveries.push(d);

        emit Delivered(
            deliveries.length - 1,
            msg.sender,
            token,
            amount,
            intentId,
            usdcRecipient
        );
    }

    /**
     * @notice Simple version — just prove the bridge can call a function on this contract.
     *         No token movement, just data.
     */
    function ping(bytes32 message) external {
        emit Delivered(
            deliveries.length,
            msg.sender,
            address(0),
            0,
            message,
            address(0)
        );
    }

    /// @notice View total deliveries
    function deliveryCount() external view returns (uint256) {
        return deliveries.length;
    }

    /// @notice Owner can withdraw any tokens sent here during testing
    function rescue(address token, address to, uint256 amount) external {
        if (msg.sender != owner) revert Unauthorized();
        (bool ok,) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        require(ok, "transfer failed");
    }
}
