# RIVR — AI- and Agent-Native Programmable Stablecoin

**Status**: design / pre-launch
**Last updated**: 2026-05-01

---

The stablecoin landscape in May 2026 is crowded — PYUSD, USDC, USDT, RLUSD, USDS, plus a growing field of "agentic" payment offerings layered over them (MoonPay's agentic debit card, Coinbase x402, Stripe Tempo, Circle Programmable Wallets). What every offering on the market has in common is the same architectural shape: a regular ERC-20 stablecoin underneath, with agent-flavored UX, mandate logic, and compliance hooks bolted on at the wallet, gateway, or orchestration layer.

That works. It's also easy to replicate. Any team with three weeks and a Stripe acquisition can ship "agentic" UX over an existing stable.

**RIVR is built differently.** RIVR is the first stablecoin where AI- and agent-native semantics live *in the token*, not above it. Six things make that real, and the moat is not any single one of them — it is the integrated stack that surrounds the token. The token by itself is straightforward; the surrounding stack of identity, policy, settlement, and compliance integration is what's structurally hard to replicate.

### What makes RIVR structurally different

**1. Tri-authoritative settlement.** RIVR's authoritative state lives on three rails simultaneously: **Canton** (via Tenzro's Global Synchronizer validator) for institutional flows that need privacy groups and atomic delivery-vs-payment; **EVM L2s** (Base, Arbitrum, Optimism, Polygon) for the bulk of agent micropayment volume; and **Solana** (SPL Token-2022) for the highest-throughput inference and data-purchase flows where confidential transfers and per-block finality matter. Each rail's authoritative copy of RIVR runs the issuance and burn logic that's appropriate for its trust model. Cross-rail movement happens through Chainlink CCIP (CCT-registered), CCTP V2 for the USDC reserve leg, and Wormhole NTT for Solana — but the rails themselves *all* see RIVR as their token, not as a wrapped derivative. This is significantly more engineering than a single-home design and meaningfully harder to clone, because no other stable issuer has tri-authoritative state running today.

**2. Mandate-bound transfers at the token level.** Every RIVR transfer carries a mandate envelope: principal identity, agent identity, intent class, spending caps, asset allowlist, expiry, and a hash of the AP2 IntentMandate that authorized the action. The token contract validates the mandate at the moment of transfer — not the wallet, not a gateway, not "trust the agent." A revoked mandate, an expired session key, a per-tx cap exceeded — the transfer reverts with a typed reason. This is what "agent-native" means in code: the token is the policy boundary, and policy is unbypassable. PYUSD and USDC validate nothing of this kind.

**3. KYA, Travel-Rule, and jurisdiction-aware compliance, baked in.** Mastercard's KYA registry, FATF Travel Rule, and per-jurisdiction de minimis thresholds are not features Rivier "supports" — they are functions the RIVR contract calls before settling a transfer. A counterparty without a valid Know-Your-Agent verifiable credential cannot receive a transfer above the configured threshold. A cross-VASP transfer above the destination jurisdiction's de minimis cannot complete without an IVMS 101-shaped originator/beneficiary envelope on-chain. Sanctions screening runs as an oracle hook before mint and before any transfer above a threshold. Compliance is contract-enforced, not policy-engine-enforced.

**4. AI-native data shapes.** Every RIVR transfer carries a structured intent class (`inference_call`, `data_purchase`, `subscription`, `royalty_split`, `invoice_settle`, `agent_to_agent`, ~20 in total) and a typed memo schema bound to that class. For agent-authorized transfers, the transfer event additionally records the model ID + version + confidence score + a hash of the agent's reasoning trace. This makes RIVR's transaction graph queryable as a structured corpus — an LLM can read its own payment history, an auditor can replay the model state that authorized any transfer, a developer can semantically search for "all subscription payments to provider X under mandate Y." No other stable carries this metadata.

**5. Native programmable batching with mandate-aware caps.** RIVR's `batchProgrammableTransfer` is not a smart-wallet trick layered over `transferFrom`; it's a token-contract function that takes a mandate envelope, a recipient list, an amounts list, and an instructions list, and atomically settles all legs while enforcing the mandate's cumulative cap at the token level. This is what agent micropayment economics actually need: 1,000 sub-cent transfers settling for a fraction of a cent each, with a single mandate authorization, with the cap enforced inside the contract. Visa Agent Pay and Mastercard's roadmap describe this; only RIVR ships it.

**6. Continuous settlement, not just discrete transfers.** Agents do not transact like humans. Humans make large discrete payments; agents emit constant tiny settlement streams — pay per inference token, pay per API call, pay per second of compute, pay per sensor read, pay per satellite tile, pay per autonomous task completion. RIVR ships a token-level streaming primitive (`openStream`, `withdrawFromStream`, `closeStream`) where a stream carries its own mandate, accrues at a `ratePerSecond`, and auto-pauses if the mandate's cumulative cap is reached or the agent's KYA credential is revoked. Discrete `transferWithMandate` covers x402-style per-call flows; streams cover the per-second-of-compute case. Both are required to claim the agentic-economy surface — and only RIVR has both in the token, not bolted on at the orchestration layer.

### What RIVR is *not*

It is not a speculative asset. RIVR is reserve-backed 1:1 in USD-denominated assets (USDC, USDT, short-duration U.S. Treasuries) with an on-chain Chainlink Proof-of-Reserve gate that reverts mints exceeding attested reserves. It is not a layer-1 chain. It is not a payment protocol or a wallet. It is the settlement asset that AP2 IntentMandates, x402 micropayments, KYA-attested agent identities, and Canton-style atomic DvP all settle into.

### Why this is hard to replicate

We want to be honest about this: anyone can issue a stablecoin now. The token contract is the *least* defensible piece of the stack. A competent team could redeploy RIVR's contract surface — even the mandate-bound + streaming + batched programmable parts — in 8–12 weeks. That is not where the moat lives.

The moat is the integrated stack that the token plugs into:

- **Agent identity issuance.** Rivier operates `did:web:identity.rivier.ai` as a W3C VC issuer. Agents transact under verifiable credentials Rivier signs and counterparty systems verify. Mastercard's KYA registry, x402 sellers, and regulators can resolve the issuer key and validate any agent VC without Rivier-side intervention. Standing up a credible issuer relationship — including the operational rotation, revocation freshness, and audit posture — takes well over a year.
- **Policy orchestration.** RIVR's `RivierPolicyHook` composes six oracles: KYA, sanctions, Travel Rule (FATF / IVMS 101), jurisdiction, velocity, counterparty classification. Each oracle is its own integration: Notabene/Sumsub for Travel Rule, Chainalysis-grade sanctions screening, per-jurisdiction de minimis tables. Wiring this in real, not in a policy-engine-bolted-onto-a-wallet, requires a regulatory posture most issuers don't have.
- **Cross-rail settlement.** CCIP CCT registration with role-split admin (CCIP_ADMIN ≠ DEFAULT_ADMIN), CCTP V2 for the USDC reserve leg, Wormhole NTT for Solana, plus the off-chain coordinator that reconciles supply across three authoritative rails. Each integration is months of work; doing all four with consistent semantics is a quarter or more.
- **Reserve attestation + audit posture.** Chainlink Proof-of-Reserve feed wired as a contract-level mint gate (mints revert when reserves are insufficient or feed is stale). A real reserve relationship with a custodian. A real audit firm. These are operational moats, not technical ones, and they take 6–12 months to stand up credibly.
- **The curator + MCP integration.** Building an agent SDK that emits AP2 IntentMandates with structured constraints, signs them with the principal's threshold key, presents them to RIVR transfers, and exposes the full surface through MCP for any third-party agent — that's the integration that makes RIVR usable, and it's the work that has no shortcut.

**The Canton via Tenzro relationship is the deepest moat.** Becoming a Canton Global Synchronizer validator is not a self-service step; it is a relationship and infrastructure investment. Rivier's relationship to Canton through Tenzro lets RIVR transact in the same privacy groups as Goldman DAP, Broadridge DLR, BNY LiquidityDirect, DTCC ComposerX, and Versana — the institutional rail of tokenized fixed income and fund settlement. No other stable issuer has this position, and no competitor can replicate it without a similar relationship.

RIVR-the-token is straightforward. RIVR-the-system encodes 18 months of identity, policy, compliance, settlement, and reserve work that competitors have not done — and the technical features in the token are how that work becomes legible to the chain.

### What this enables

For a developer building agent commerce: spend 10 minutes wiring the Rivier MCP server, get an agent that can pay for inference, subscribe to data feeds, settle invoices, and split royalties — with mandate-bound caps, KYA-verified counterparties, structured audit trails, and Travel-Rule compliance, on the rails the institutional world settles on.

For a treasury team: hold a stablecoin that programmatically refuses transfers that violate your mandate, that emits structured Travel-Rule envelopes regulators already accept, and that settles natively on Canton alongside the tokenized treasuries you already own.

For a regulator: every flow is auditable as a typed event stream with attestations, mandate hashes, model identities, and reserve PoR timestamps. The audit posture is "show your auditor the chain"; everything else is decoration.
