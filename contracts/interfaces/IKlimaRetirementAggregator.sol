// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IKlimaRetirementAggregator
 * @notice Interface for the Carbonmark Retirement Aggregator (Diamond) — Path 2: Klima-mediated retirement.
 *         Base Mainnet: 0xda0a793d7c32ab80bcdab7f8c725c96db22464f4
 *         Base Sepolia:  0xc0309c29162f699a3445a7a9aeb0acbe568f5fe0
 */
interface IKlimaRetirementAggregator {
    /**
     * @notice Metadata attached to every retirement. All string fields default gracefully
     *         (retiringAddress → msg.sender, retiringEntityString → "Carbonmark Retirement Aggregator").
     *         For Toucan Puro credits the location / country / period fields are required.
     */
    struct RetireDetails {
        address retiringAddress;
        string retiringEntityString;
        address beneficiaryAddress;
        string beneficiaryString;
        string retirementMessage;
        string beneficiaryLocation;
        string consumptionCountryCode;
        uint256 consumptionPeriodStart;
        uint256 consumptionPeriodEnd;
    }

    /**
     * @notice Get a price quote for retiring `amount` tonnes via Klima.
     * @param creditToken   Carbon credit token address
     * @param tokenId       ERC-1155 token ID (0 for ERC-20 credits)
     * @param amount        Tonnes to retire
     * @param inputToken    kVCM or USDC
     * @param carbonClass   Carbon class vault address for this credit
     * @param couponTonnes  Pass 0 (no coupons currently issued)
     * @return tonnes       Actual tonnes that will be retired
     * @return price        Input token cost for the retirement
     */
    function quoteRetireCreditViaKlima(
        address creditToken,
        uint256 tokenId,
        uint256 amount,
        address inputToken,
        address carbonClass,
        uint256 couponTonnes
    ) external view returns (uint256 tonnes, uint256 price, uint256, uint256);

    /**
     * @notice Retire carbon credits sourced via Klima Protocol, paying with kVCM or USDC.
     *         For kVCM: caller must approve the Klima AAM (not this contract) for `maxInputTokenIn`.
     *         For USDC: caller must approve this contract for `maxInputTokenIn`.
     * @param creditToken       Carbon credit token address
     * @param tokenId           ERC-1155 token ID (0 for ERC-20 credits)
     * @param batchId           Required for Puro retirements; pass 0 otherwise
     * @param amount            Tonnes to retire
     * @param inputToken        kVCM or USDC address
     * @param carbonClass       Carbon class vault address for the credit
     * @param maxInputTokenIn   Max input tokens to spend (slippage protection)
     * @param couponTonnes      Pass 0 (no coupons currently issued)
     * @param details           Retirement metadata
     */
    function retireCreditViaKlima(
        address creditToken,
        uint256 tokenId,
        uint256 batchId,
        uint256 amount,
        address inputToken,
        address carbonClass,
        uint256 maxInputTokenIn,
        uint256 couponTonnes,
        RetireDetails calldata details
    ) external;
}
