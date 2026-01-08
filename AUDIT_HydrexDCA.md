# Security Audit Report: HydrexDCA Contract

**Contract:** HydrexDCA.sol  
**Audit Date:** January 8, 2026 (Updated after upgradeability implementation)  
**Auditor:** Security Review  
**Solidity Version:** 0.8.26  
**Pattern:** Transparent Upgradeable Proxy

---

## Executive Summary

The HydrexDCA contract is a custodial Dollar-Cost Averaging protocol that holds user funds and executes automated token swaps. The contract has been upgraded to use OpenZeppelin's Transparent Proxy pattern for upgradeability.

**Updated Analysis:** This audit identifies **6 Critical**, **4 High**, **5 Medium**, and **8 Low** severity issues, plus several code quality recommendations.

**Overall Risk Assessment:** HIGH - Multiple critical vulnerabilities that could result in loss of user funds.

**Recent Changes:**

- ✅ Converted to upgradeable pattern (AccessControlUpgradeable, ReentrancyGuardUpgradeable)
- ✅ Implemented initialize() function replacing constructor
- ✅ Added HydrexDCAProxy for transparent proxy pattern
- ⚠️ **NEW ISSUE:** Storage layout management for upgrades (see issue #30)

**Note:** All previously identified issues remain present in the upgraded version.

---

## Upgradeability-Specific Issues

### 30. **Storage Layout Not Protected for Upgrades (LOW)**

**Location:** Contract-wide

**Issue:** The contract uses an upgradeable pattern but doesn't include storage gap for future upgrades. If you need to add new state variables in a future upgrade, they could clash with child contract storage if anyone inherits from this contract.

**Impact:** Future upgrade flexibility limited, potential storage collision in edge cases.

**Recommendation:**

```solidity
/**
 * @dev This empty reserved space is put in place to allow future versions to add new
 * variables without shifting down storage in the inheritance chain.
 * See https://docs.openzeppelin.com/contracts/4.x/upgradeable#storage_gaps
 */
uint256[50] private __gap;
```

---

### 31. **Initializer Not Protected Against Re-initialization (MEDIUM)**

**Location:** `initialize()` function, line 188

**Issue:** While OpenZeppelin's `initializer` modifier protects against re-initialization, the contract doesn't use `_disableInitializers()` in the constructor to prevent the implementation contract itself from being initialized. This could lead to implementation contract being initialized by an attacker.

**Impact:** While not immediately exploitable for funds theft, allows implementation to be initialized which violates security best practices.

**Recommendation:**

```solidity
/// @custom:oz-upgrades-unsafe-allow constructor
constructor() {
    _disableInitializers();
}

function initialize(address _admin, address _operator, address _feeRecipient) public initializer {
    // ... existing code
}
```

---

## Critical Severity Issues

### 1. **Arbitrary External Call Vulnerability (CRITICAL)**

**Location:** `_executeSwap()` function, lines 376-378

```solidity
(bool success, bytes memory returnData) = swap.router.call{value: isETH ? swap.amountIn : 0}(
    swap.routerCalldata
);
```

**Issue:** The contract allows operators to execute arbitrary calldata on whitelisted routers. While routers are whitelisted, operators can craft malicious calldata to:

- Call unexpected functions (e.g., `transferFrom` with arbitrary parameters)
- Manipulate contract state
- Drain funds if router has vulnerabilities
- Execute complex multi-call operations

**Impact:** Complete loss of user funds, unauthorized token transfers.

**Recommendation:**

- Implement a strict swap function signature validation
- Use a standardized router interface instead of arbitrary calldata
- Validate the function selector in the calldata matches expected swap functions
- Consider implementing a proxy pattern with explicit function calls

```solidity
// Example fix:
interface ISwapRouter {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut) external payable returns (uint256);
}

// In _executeSwap:
uint256 returnAmount = ISwapRouter(swap.router).swap{value: isETH ? swap.amountIn : 0}(
    order.tokenIn,
    order.tokenOut,
    swap.amountIn,
    swap.minAmountOut
);
```

---

### 2. **Integer Division Truncation Leading to Loss of Funds (CRITICAL)**

**Location:** `_createOrder()` function, line 294

```solidity
uint256 amountPerSwap = totalAmount / numberOfSwaps;
```

**Issue:** When `totalAmount` is not perfectly divisible by `numberOfSwaps`, the remainder is lost. For example:

- User deposits 100 tokens, wants 3 swaps
- `amountPerSwap = 100 / 3 = 33` (truncated)
- Total used: `33 * 3 = 99` tokens
- 1 token permanently locked in contract

**Impact:** User funds permanently locked, cannot be recovered through normal operations.

**Recommendation:**

```solidity
uint256 amountPerSwap = totalAmount / numberOfSwaps;
uint256 actualTotal = amountPerSwap * numberOfSwaps;
require(actualTotal == totalAmount, "Amount not divisible");
// OR store remainder and handle it in last swap
```

---

### 3. **No Slippage Protection Enforcement (CRITICAL)**

**Location:** `_executeSwap()` function, lines 402-405

```solidity
if (swap.minAmountOut != 0 && returnAmount < swap.minAmountOut) {
    emit DCASwapFailed(swap.orderId, order.user, "Insufficient return amount");
    return;
}
```

**Issue:**

- Operators can set `swap.minAmountOut = 0` to bypass slippage protection
- User's `order.minAmountOut` is stored but never enforced
- Operators can execute swaps with 100% slippage, essentially stealing funds

**Impact:** Complete loss of user funds through intentional or accidental bad swaps.

**Recommendation:**

```solidity
// Enforce user's slippage preference
uint256 requiredMinAmount = order.minAmountOut * swap.amountIn / order.amountPerSwap;
if (returnAmount < requiredMinAmount) {
    emit DCASwapFailed(swap.orderId, order.user, "Insufficient return amount");
    return;
}
```

---

### 4. **Reentrancy in ETH Transfer (CRITICAL)**

**Location:** `_transfer()` function, lines 470-473

```solidity
if (token == address(0) || token == 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE) {
    (bool success, ) = payable(to).call{value: amount}("");
    require(success, "ETH transfer failed");
}
```

**Issue:** While `_executeSwap` is protected by `nonReentrant`, the ETH transfer could still be exploited:

- If `to` is a malicious contract (order.user)
- During fee transfer to malicious feeRecipient
- Could manipulate state before `nonReentrant` protection

**Impact:** Potential reentrancy attacks, double-spending of funds.

**Recommendation:**

```solidity
// Use Address.sendValue() or transfer() with proper checks
// Ensure state updates happen before external calls (CEI pattern)
// Consider adding reentrancy guard specifically for transfer operations
```

---

### 5. **Emergency Recover Function Can Steal User Funds (CRITICAL)**

**Location:** `emergencyRecover()` function, lines 595-601

```solidity
function emergencyRecover(address token, uint256 amount, address recipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
    if (recipient == address(0)) revert InvalidAddress();
    if (amount == 0) revert InvalidAmounts();
    _transfer(token, recipient, amount);
}
```

**Issue:**

- No validation that funds being recovered are not user deposits
- Admin can drain all user DCA funds
- Comment says "only non-custodial funds" but no enforcement
- Single point of failure (compromised admin key = total loss)

**Impact:** Complete loss of all user funds if admin key compromised.

**Recommendation:**

```solidity
// Track total user deposits per token
mapping(address => uint256) public totalUserDeposits;

// Update in createOrder:
totalUserDeposits[tokenIn] += totalAmount;

// Update in cancelOrder and _executeSwap:
totalUserDeposits[order.tokenIn] -= amount;

// In emergencyRecover:
uint256 available = _getBalance(token) - totalUserDeposits[token];
require(amount <= available, "Cannot recover user funds");
```

---

### 6. **Order Counter Overflow (CRITICAL on long timeframes)**

**Location:** Line 295

```solidity
orderId = orderCounter++;
```

**Issue:** While Solidity 0.8.26 has overflow protection, if `orderCounter` reaches `type(uint256).max`, all future order creation will revert. Given 2^256 orders is practically impossible, this is more of a theoretical issue but could DoS the contract.

**Impact:** Contract becomes unusable for new orders.

**Recommendation:** This is very low probability but could use SafeMath or simply acknowledge the limitation.

---

### 6. **Order Counter Overflow (CRITICAL on long timeframes)**

**Location:** Line 308

```solidity
orderId = orderCounter++;
```

**Issue:** While Solidity 0.8.26 has overflow protection, if `orderCounter` reaches `type(uint256).max`, all future order creation will revert. Given 2^256 orders is practically impossible, this is more of a theoretical issue but could DoS the contract.

**Impact:** Contract becomes unusable for new orders.

**Recommendation:** This is very low probability but could use SafeMath or simply acknowledge the limitation.

**Status:** ✅ ACKNOWLEDGED - Solidity 0.8.26 will revert on overflow which is acceptable behavior (DoS vs silent failure). Theoretical limitation.

---

## High Severity Issues

### 7. **Fee-on-Transfer Token Support Broken (HIGH)**

**Location:** `createOrder()` function, lines 236-244

```solidity
uint256 balanceBefore = IERC20(tokenIn).balanceOf(address(this));
IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), totalAmount);
uint256 balanceAfter = IERC20(tokenIn).balanceOf(address(this));
uint256 actualReceived = balanceAfter - balanceBefore;

// Validate we received exactly what was expected
if (actualReceived != totalAmount) revert InvalidAmounts();
```

**Issue:**

- Code attempts to handle fee-on-transfer tokens by measuring actual received amount
- But then REVERTS if actual != expected, making it impossible to use FoT tokens
- This contradicts the purpose of the balance check

**Impact:** Fee-on-transfer tokens cannot be used, or users lose funds on deposits that get reverted.

**Recommendation:**

```solidity
// Either support FoT tokens by using actualReceived:
if (actualReceived == 0) revert InvalidAmounts();
totalAmount = actualReceived; // Use actual received amount

// OR explicitly disallow them:
// Document that FoT tokens are not supported
```

---

### 8. **Race Condition in batchSwap (HIGH)**

**Location:** `batchSwap()` function, lines 269-273

```solidity
function batchSwap(SwapData[] calldata swaps) external onlyRole(OPERATOR_ROLE) nonReentrant {
    for (uint256 i = 0; i < swaps.length; i++) {
        _executeSwap(swaps[i]);
    }
}
```

**Issue:**

- Multiple operators can call `batchSwap` simultaneously
- `nonReentrant` only prevents reentrancy within same transaction
- Two operators could execute the same order ID in parallel
- Could lead to double-spending if timing is right

**Impact:** Potential double-execution of swaps, loss of funds.

**Recommendation:**

```solidity
// Add order-level locking or execution tracking
mapping(uint256 => bool) private executing;

function _executeSwap(SwapData calldata swap) internal {
    require(!executing[swap.orderId], "Already executing");
    executing[swap.orderId] = true;

    // ... existing logic ...

    executing[swap.orderId] = false;
}
```

---

### 9. **Operator Can Manipulate Order Execution (HIGH)**

**Location:** `_executeSwap()` function

**Issue:**

- Operator controls `swap.amountIn` which can be different from `order.amountPerSwap`
- Operator can execute smaller swaps to extend order duration
- Operator can execute order.remainingAmount in fewer swaps than intended
- No validation that execution follows user's intent

**Impact:** User's DCA strategy is not executed as intended, potential for MEV extraction.

**Recommendation:**

```solidity
// Enforce amount matches expected or is last swap
if (swap.amountIn != order.amountPerSwap) {
    // Only allow if this is the final swap with remaining amount
    require(order.remainingAmount < order.amountPerSwap, "Must use amountPerSwap");
    require(swap.amountIn == order.remainingAmount, "Must swap all remaining");
}
```

---

### 10. **No Deadline for Swap Execution (HIGH)**

**Location:** `Order` struct and `_executeSwap()`

**Issue:**

- Orders have no expiration timestamp
- Orders can sit unfilled indefinitely
- Market conditions can change drastically
- Users cannot specify a deadline for when DCA should complete

**Impact:** Stale orders executed at unfavorable prices, user funds locked indefinitely.

**Recommendation:**

```solidity
struct Order {
    // ... existing fields ...
    uint256 deadline; // Timestamp after which order expires
}

// In _executeSwap:
if (block.timestamp > order.deadline) {
    order.status = OrderStatus.Expired;
    emit OrderExpired(swap.orderId, order.user);
    return;
}
```

---

## Medium Severity Issues

### 11. **No Maximum Interval Validation (MEDIUM)**

**Location:** `_createOrder()` function

**Issue:**

- Only `minimumInterval` is checked
- User could set interval to years or decades
- Funds locked with unrealistic execution schedule

**Impact:** User funds locked for excessive periods.

**Recommendation:**

```solidity
uint256 public constant MAX_INTERVAL = 365 days;

// In _createOrder:
require(interval <= MAX_INTERVAL, "Interval too long");
```

---

### 12. **Protocol Fee Applied Before Slippage Check (MEDIUM)**

**Location:** `_executeSwap()` function, lines 417-426

```solidity
uint256 protocolFee = (returnAmount * protocolFeeBps) / 10000;
uint256 userAmount = returnAmount - protocolFee;
```

**Issue:**

- Fee is calculated on gross return, not net after slippage
- If swap returns minimum amount, user pays full fee even at max slippage
- User receives less than `minAmountOut` due to fee

**Impact:** Users receive less than their specified minimum, potential loss.

**Recommendation:**

```solidity
// Check slippage on amount AFTER fees
uint256 protocolFee = (returnAmount * protocolFeeBps) / 10000;
uint256 userAmount = returnAmount - protocolFee;

// Validate user gets at least minimum
uint256 requiredMinAmount = order.minAmountOut * swap.amountIn / order.amountPerSwap;
require(userAmount >= requiredMinAmount, "Insufficient after fees");
```

---

### 13. **Inconsistent ETH Address Representation (MEDIUM)**

**Location:** Multiple locations

**Issue:**

- Uses `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` for ETH in some places
- Uses `address(0)` in others
- Inconsistent checks in `_getBalance()` and `_transfer()`

**Impact:** Potential bugs, failed transactions, confusion.

**Recommendation:**

```solidity
address public constant ETH_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

// Use consistently throughout contract
```

---

### 14. **Gas Grief Attack via Large Batch (MEDIUM)**

**Location:** `batchSwap()` function

**Issue:**

- No limit on array size for `batchSwap`
- Operator could submit massive array causing out-of-gas
- Could block execution for extended period

**Impact:** DoS of swap execution functionality.

**Recommendation:**

```solidity
uint256 public constant MAX_BATCH_SIZE = 50;

function batchSwap(SwapData[] calldata swaps) external onlyRole(OPERATOR_ROLE) nonReentrant {
    require(swaps.length <= MAX_BATCH_SIZE, "Batch too large");
    // ...
}
```

---

### 15. **Order Cancellation During Swap Execution (MEDIUM)**

**Location:** `cancelOrder()` and `_executeSwap()`

**Issue:**

- User can cancel order while swap is being executed in separate transaction
- `nonReentrant` doesn't prevent cross-transaction conflicts
- Could result in failed swaps or inconsistent state

**Impact:** Failed transactions, gas waste, potential state inconsistencies.

**Recommendation:**

```solidity
// Add execution lock as mentioned in issue #8
// Or check status more granularly
```

---

## Low Severity Issues

### 16. **Missing Event for Order Updates (LOW)**

**Location:** `_executeSwap()` function

**Issue:** No event emitted for order state changes like `remainingAmount` updates during partial execution.

**Recommendation:** Add `OrderUpdated` event.

---

### 17. **No Pause Mechanism (LOW)**

**Location:** Contract level

**Issue:** No way to pause contract in emergency situations.

**Recommendation:** Implement OpenZeppelin's Pausable pattern.

---

### 18. **userOrders Array Can Grow Unbounded (LOW)**

**Location:** `userOrders` mapping, line 40

**Issue:**

- Each order is pushed to array
- No way to remove completed/cancelled orders
- Could become expensive to iterate over time

**Recommendation:**

```solidity
// Add function to prune completed orders
function pruneCompletedOrders(address user, uint256 maxIterations) external {
    // Remove completed/cancelled orders from array
}
```

---

### 19. **No Protection Against Dust Amounts (LOW)**

**Location:** `_executeSwap()` function

**Issue:** Very small amounts could be swapped, potentially costing more in gas than value.

**Recommendation:**

```solidity
uint256 public minimumSwapAmount = 1e15; // 0.001 tokens minimum

// In _executeSwap:
require(swap.amountIn >= minimumSwapAmount, "Amount too small");
```

---

### 20. **Missing Zero Address Check in createOrder (LOW)**

**Location:** `createOrder()` function

**Issue:** `tokenOut` is checked for zero address, but `tokenIn` (for ERC20) relies on the SafeERC20 call to fail.

**Recommendation:** Add explicit check for clarity.

---

### 21. **forceApprove May Not Work With All Tokens (LOW)**

**Location:** `_executeSwap()` function, lines 372, 384, 390

```solidity
IERC20(order.tokenIn).forceApprove(swap.router, swap.amountIn);
```

**Issue:** Some tokens don't handle approve(0) -> approve(X) pattern well.

**Recommendation:** Use `safeIncreaseAllowance` or validate token compatibility.

---

### 22. **No Validation of numberOfSwaps Upper Bound in Tests (LOW)**

**Location:** Contract uses `maxSwaps` but default is 100

**Issue:** 100 swaps could be excessive for most use cases, consider lower default.

---

## Code Quality Issues

### 23. **Misleading Comment in emergencyRecover**

**Location:** Line 592

```solidity
* @notice Emergency function to recover stuck tokens (only non-custodial funds)
```

**Issue:** Comment claims "only non-custodial funds" but no such enforcement exists.

**Recommendation:** Either implement the restriction or update the comment.

---

### 24. **Inconsistent Error Handling in \_executeSwap**

**Location:** `_executeSwap()` function

**Issue:** Function uses early returns with event emission instead of reverting, making it difficult to track failures off-chain.

**Recommendation:** Consider reverting on critical failures or implement better off-chain tracking.

---

### 25. **Magic Numbers**

**Location:** Multiple locations

```solidity
if (returnData.length < 68) return "Swap failed";
```

**Issue:** Magic number 68 with no explanation.

**Recommendation:** Add comment explaining why 68 bytes (4-byte selector + 32-byte offset + 32-byte length).

---

### 26. **Unused Return Value**

**Location:** Multiple locations

**Issue:** `_transfer()` doesn't return success/failure, inconsistent with SafeERC20 patterns.

---

### 27. **No NatSpec for Some Functions**

**Location:** `_getBalance()`, `_transfer()`, etc.

**Recommendation:** Add comprehensive NatSpec documentation for all functions.

---

### 28. **ETH Handling Could Be More Gas Efficient**

**Location:** `_transfer()` function

**Issue:** Using `.call{value: amount}("")` is more expensive than `.transfer()` or `.send()` in some cases.

**Recommendation:** Consider using OpenZeppelin's `Address.sendValue()` for consistency.

---

### 29. **Missing Input Validation**

**Location:** `getUserOrdersPaginated()`

**Issue:** No validation that `limit` is reasonable, could cause out-of-gas.

**Recommendation:**

```solidity
require(limit <= 100, "Limit too high");
```

---

## Testing Gaps

Based on the test file, the following scenarios need additional coverage:

1. ✗ Fee-on-transfer token handling
2. ✗ Concurrent order execution by multiple operators
3. ✗ Integer division remainder loss
4. ✗ Reentrancy attack scenarios
5. ✗ Very large batch swap arrays (gas limits)
6. ✗ Order execution with manipulated amountIn
7. ✗ Emergency recover of user funds
8. ✗ Slippage bypass by operator setting minAmountOut=0
9. ✗ ETH balance tracking across multiple orders
10. ✗ Fee calculation edge cases (100% fee, 0 fee)

---

## Gas Optimization Opportunities

1. **Pack struct Order** - Some fields could be packed to save storage slots
2. **Cache array length** in loops
3. **Use unchecked blocks** where overflow is impossible
4. **Batch whitelist checks** - Use bitmap instead of mapping for gas efficiency
5. **Remove redundant balance checks** where SafeERC20 provides protection

---

## Recommendations Summary

### Immediate Actions (Critical/High):

1. ✅ **Fix arbitrary external call vulnerability (#1)** - Implement strict interface or function selector validation
2. ✅ **Fix integer division truncation (#2)** - Validate or handle remainder properly
3. ✅ **Enforce user's slippage protection (#3)** - Use order.minAmountOut in validation
4. ✅ **Add reentrancy protection to ETH transfers (#4)** - Use CEI pattern or check effects
5. ✅ **Implement user fund tracking in emergencyRecover (#5)** - Track total deposits per token
6. ✅ **Fix fee-on-transfer token handling (#7)** - Either support or explicitly disallow
7. ✅ **Add order-level execution locking (#8)** - Prevent concurrent execution
8. ✅ **Validate swap amounts match expected (#9)** - Enforce amountPerSwap or last swap logic
9. ✅ **Implement order deadline (#10)** - Add expiration timestamp to orders

### Upgradeability Actions (Medium):

10. ✅ **Add storage gap (#30)** - Reserve storage slots for future upgrades
11. ✅ **Disable initializers in constructor (#31)** - Prevent implementation initialization

### Short-term Actions (Medium):

12. Add maximum interval validation (#11)
13. Adjust fee application logic (#12)
14. Standardize ETH address constant (#13)
15. Add batch size limit (#14)
16. Improve order cancellation protection (#15)

### Long-term Improvements (Low/Quality):

17. Implement pause mechanism (#17)
18. Add comprehensive event logging (#16)
19. Implement order pruning (#18)
20. Add minimum swap amounts (#19)
21. Improve error handling consistency (#24)
22. Complete test coverage for edge cases

---

## Conclusion

The HydrexDCA contract has been successfully upgraded to use a Transparent Proxy pattern for upgradeability, following the patterns used in the main Hydrex contracts repository. However, all previously identified security vulnerabilities remain present.

**Critical Next Steps:**

1. Implement storage gap and disable initializers (upgradeability best practices)
2. Address the 6 critical and 4 high severity security issues
3. Add comprehensive tests for upgrade scenarios
4. Perform upgrade safety validation using OpenZeppelin Upgrades plugin

**Key Vulnerabilities Still Present:**

- Arbitrary external calls via routerCalldata
- Lack of slippage enforcement
- Integer division loss of funds
- Emergency recover can drain user funds
- Multiple operator manipulation vectors

After addressing the critical and high-severity issues, the contract should undergo another security review and comprehensive testing before handling real user funds. Consider a professional third-party audit before production deployment.

**Estimated remediation time:** 1-2 weeks for critical fixes + upgradeability improvements, additional week for thorough testing and upgrade validation.

The HydrexDCA contract has a solid foundation with good use of OpenZeppelin contracts and access control. However, it contains several critical vulnerabilities that must be addressed before production deployment:

- **Arbitrary external calls** pose the highest risk
- **Lack of slippage enforcement** could be exploited
- **Emergency recover function** needs strict safeguards
- **Integer division** needs proper handling

After addressing the critical and high-severity issues, the contract should undergo another security review and comprehensive testing before handling real user funds.

**Estimated remediation time:** 1-2 weeks for critical fixes, additional week for thorough testing.

---

**Disclaimer:** This audit does not guarantee the absence of vulnerabilities. A comprehensive formal verification and professional third-party audit is recommended before production deployment.
