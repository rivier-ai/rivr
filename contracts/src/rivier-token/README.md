# RIVR — launch contract suite

This directory carries the **launch** RIVR contract suite — the
single absolute-replacement PR that lands the irreducible RIVR
surface on every chain RIVR ships on, with no migration of
testnet balances and no Phase-0 backcompat shims. See
`docs/architecture/2026-rivr-design.md` §"Launch — single
absolute-replacement PR" for the design rationale.

## What's first-of-its-kind here

RIVR is the **first stablecoin where mandate validation, agent
attestation, programmable batching, and continuous settlement
streams are token-contract primitives** — not orchestration above
an inert ERC-20. As of May 2026, comparing against every shipped
competitor (PYUSD, USDC + CCTP V2 + x402, USDT, RLUSD, USDS/sUSDS,
Stripe Tempo TIP-20/TIP-403, MoonPay PYUSDx, Backed xStocks):

| Primitive | RIVR | Closest neighbor | Verdict |
|---|---|---|---|
| `transferWithMandate` (multi-constraint EIP-712 envelope verified in-token: per-tx cap + cumulative cap + asset allowlist + KYA hash + EIP-1271 fall-through) | Yes | Coinbase x402 / EIP-3009 `transferWithAuthorization` — single-tx, no caps | **First in-token** |
| `IntentClass` + versioned `extensionData` (agent attestation as typed event field: model ID, version, confidence, reasoning hash, prompt hash, MCP server DID, TEE attestation hash, policy compliance proof) | Yes | Mastercard KYA / Google AP2 / Visa TAP — credential standards, off-chain | **First in-token** |
| `batchProgrammableTransfer` (one mandate signature, atomic, sum-checked once against cumulative cap) | Yes | ERC-20 multisends (Disperse, Multisend) — stateless | **First in-token** |
| Continuous settlement streams (`openStream`/`withdrawFromStream`) with policy-aware auto-pause | Yes | Sablier Flow / Superfluid — wrappers above tokens | **First in-token** |
| Multi-oracle PolicyHook composition (KYA + Chainalysis + Travel Rule + jurisdiction/velocity/counterparty/RWA slots) behind 7-day timelock + freeze milestone | Yes | Stripe Tempo TIP-403 (single whitelist/blacklist); USDC `Blacklistable` (single sanctions list) | **Differentiator** — pattern predates, multi-oracle composition is novel |
| Tri-authoritative settlement (Canton DAML + EVM + Solana SPL with same logical token, Canton via Tenzro validator → same DVP privacy groups as Goldman DAP / BNY LD / DTCC ComposerX) | Yes | USDC multi-chain via CCTP V2 (bridge-mirror); PYUSD on ETH+SOL | **Differentiator** — degree-of-symmetry argument |

**The honest pitch (use verbatim in landing copy / talks / ERC drafts)**:

> RIVR is the first stablecoin where mandate validation, agent
> attestation, programmable batching, and continuous settlement
> streams are token-contract primitives — not orchestration above
> an inert ERC-20.

**Don't overclaim**:
- Not "first programmable stablecoin" — Tempo TIP-403 (March 2026) and USDC's `Blacklistable` predate.
- Not "first compliant stablecoin" — PYUSD/USDC have shipped pause/freeze/blacklist for years.
- Not "first multi-chain stablecoin" — USDC + CCTP V2 covers 11 chains.

**The defensible claim is the composition**, not any single primitive.
See `docs/architecture/2026-rivr-design.md` §"17.5 The moat is the
stack, not the token" for the eight-surface argument.

## Recognition pathway

Public recognition for the in-token primitives lands through three
parallel tracks. Each is merit-based; none are pay-to-play.

**Standards track** (where the patterns become referenceable specs):

1. **ERC draft on Ethereum Magicians forum → eips.ethereum.org PR.**
   Closest neighbors are live: ERC-8004 (AI-agent identity/reputation,
   mainnet Jan 29 2026) and ERC-7683 (cross-chain intents). Mandate
   envelope + agent-attestation event payload slot as an extension on
   top. Discussion-first on Magicians; get an editor + at least one
   client team to engage before formal PR.
2. **x402 Foundation (Linux Foundation)** — launched Apr 2 2026 with
   80+ partners; explicitly accepting standards proposals. Best
   single venue: x402's `transferWithAuthorization` is exactly the
   primitive RIVR's `transferWithMandate` extends. RIVR is already
   x402 buyer + seller (see CLAUDE.md §x402 micropayment rail).
3. **AP2 / FIDO Alliance working group** — Google donated AP2 to FIDO
   Alliance Apr 28 2026 (Apache 2.0,
   github.com/google-agentic-commerce/AP2). Working group chaired by
   Google/OpenAI/CVS, vice-chairs Amazon/Okta. Open contribution path.
   IntentClass + extensionData maps directly onto AP2 v0.2.
4. **Visa Trusted Agent Protocol** — published openly at
   developer.visa.com/capabilities/trusted-agent-protocol +
   github.com/visa/trusted-agent-protocol. Pull-request contributions
   accepted. Visa committed to aligning with IETF / OpenID / EMVCo.

**Audit lineage** (the most credible technical recognition):

Trail of Bits / OpenZeppelin / Spearbit reports function as published
technical recognition. github.com/trailofbits/publications archive
includes novel-primitive call-outs (Morpho, Liquity, Primitive,
Balancer have precedent). Pure merit; cost is the audit fee.
**Single highest-signal path** — book the audit before any
conference submission.

**Conference + research venues**:

- **Devcon 8 Mumbai, Nov 3–6 2026** — formal CFP via devcon.org;
  standards talks fit "core protocol" track.
- **Financial Cryptography 2027 (Tokyo, Apr 22–23 2027)** — industry
  track accepts secure-transaction novelty papers. Submission via
  fc27 program committee CFP (typically opens Q4 2026).
- **IC3 (Cornell)** — rolling industry-fellow + publication tracks;
  submit via ic3.cs.cornell.edu.
- **Chainlink CCIP case study** — editorial path, driven by integration
  depth + AUM/volume. Engage via Chainlink BD; SmartCon stage is the
  public surface for announcements. Real, not theatrical (precedent:
  Coinbase Wrapped Assets, Maple syrupUSDC, xStocks).
- **a16z crypto research / Paradigm research** — no formal submission;
  inclusion is editorial via direct contact (Tim Roughgarden at a16z,
  Dan Robinson at Paradigm).

**Recommended priority order**: Trail of Bits audit → x402 Foundation
contribution → ERC draft on Magicians → AP2/FIDO working group →
Devcon 8 CFP → FC 2027 industry track → Circle/Stripe direct
engagement → CCIP case study via integration depth.

**Avoid as primary path**:
- TOKEN2049 / most paid fintech conferences — speaker slots are
  sponsor-driven, not merit CFP.
- Pre-print SEO blog farms — dilutes the technical narrative without
  building referenceable spec lineage.
- Sibos / DTCC keynote — high signal for the institutional surface
  (Canton/Tenzro angle), low signal for ERC primitives. Pursue via
  Tenzro's existing Swift/DTCC partner BD, not direct.

See `docs/architecture/2026-rivr-design.md` §"Recognition pathway"
for the full submission checklist and target dates.

## Surface

```
src/rivier-token/
├── RivierTokenCCT.sol              # Launch RIVR token (ERC-20 + namespaces + mandate-bound flows + streams + dryRun)
├── types/
│   ├── RefusalReason.sol           # Typed enum + RivierRefused(reason, ctx) revert
│   ├── IntentClass.sol             # 22-class agent intent ontology
│   ├── MandateEnvelope.sol         # EIP-712 typed mandate, signed by principal + agent
│   ├── StreamParams.sol            # openStream input
│   ├── BatchMetadata.sol           # batchProgrammableTransfer header
│   ├── DryRunInput.sol             # dryRun input shape
│   └── DryRunResult.sol            # dryRun verdict (RefusalReason + projected cumulative)
├── registries/
│   ├── RivierKyaRegistry.sol       # On-chain KYA credential mirror (synced from did:web)
│   ├── RivierMandateRegistry.sol   # Mandate state, cumulative spend tracker, revocation
│   └── RivierStreamRegistry.sol    # Continuous-settlement streams + auto-pause
├── policy/
│   └── RivierPolicyHook.sol        # KYA + sanctions + Travel Rule oracle wiring
└── interfaces/
    ├── IBurnMintERC20.sol          # CCIP CCT integration (preserved)
    ├── IGetCCIPAdmin.sol           # CCIP admin handle (preserved)
    ├── IPoRFeed.sol                # Proof of Reserve gate (preserved)
    ├── IRateLimiter.sol            # CCIP per-lane buckets (preserved)
    ├── ITokenAdminRegistry.sol     # CCIP token admin registry (preserved)
    ├── IRivierKyaRegistry.sol
    ├── IRivierMandateRegistry.sol
    ├── IRivierStreamRegistry.sol
    ├── IPolicyHook.sol
    └── IChainalysisSanctionsList.sol
script/
└── DeployRivierCCT.s.sol           # one-shot deploy + register script
```

## What `RivierTokenCCT` carries

The launch token is the irreducible surface every consumer (agent,
wallet, batcher, bridge pool) compiles against. Phase-0 features
that didn't make the launch cut (subscriptions, conditional
transfers, escrow, joint mandates, delegation chains, asymmetric
fees, offline relay) are explicitly NOT in this contract — they
land post-launch as additive registries alongside the frozen token.

### Transfer paths

| Function | Mandate-bound? | Policy chain | Emits |
|---|---|---|---|
| `transfer(to, amount)` | No | Sanctions only (cheap path; backwards-compat for free agent↔agent flows) | `Transfer` |
| `transferFrom(from, to, amount)` | No | Sanctions only | `Transfer` |
| `transferWithMandate(to, amount, amountUsd6, namespace, mandate, intentClass, memoHash, extData)` | **Yes** | Full: KYA + mandate sig (principal+agent) + per-tx cap + asset allowlist + cumulative cap + PolicyHook (sanctions + Travel Rule) | `Transfer` + `ProgrammableTransferEvent` |
| `batchProgrammableTransfer(legs[], mandate, batchMeta)` | **Yes** (one mandate covers all legs) | Same chain, sum-checked once | one `ProgrammableTransferEvent` per leg, `transferRef = batchRef ^ legIndex` |
| `withdrawFromStream(streamRef, amount)` | Bounded by stream's mandate | Stream auto-pause invariants | `Transfer` + `ProgrammableTransferEvent` |

`ProgrammableTransferEvent` carries a versioned `extensionData` blob
(currently v1) for agent attestation: model ID, version,
confidence, reasoning hash, prompt hash, MCP server DID, TEE
attestation hash, policy compliance proof.

### Sub-balance namespaces (ERC-6909-style)

A holder's balance is partitioned across `bytes32` namespaces.
`DEFAULT_NS = bytes32(0)` is where plain ERC-20 transfers and
mints land. Per-namespace ops:

| Function | What it does |
|---|---|
| `deposit(namespace, amount)` | Move from caller's `DEFAULT_NS` → `namespace`. Sum-preserving. |
| `withdrawFromNamespace(namespace, recipient, amount)` | Pull from caller's `namespace` → recipient's `DEFAULT_NS`. |
| `transferNamespace(fromNs, toNs, amount)` | Caller-internal move. Sum-preserving on the holder. |
| `balanceOfNamespace(holder, ns) view` | Per-namespace balance. |
| `namespacesOf(holder) view` | Push-only enumeration of namespaces the holder has touched. Dedup'd. |

Invariants enforced by `RivierNamespaceInvariants.t.sol`:
- **I1** `balanceOf(holder) == sum(balanceOfNamespace(holder, ns))` for all ns the holder has touched.
- **I2** `transferNamespace` is sum-preserving on the holder.
- **I3** Namespace-bounded debits don't spill into other namespaces.
- **I4** `deposit` / `withdrawFromNamespace` are sum-preserving on the caller (when withdrawing to self).

### Streams (continuous settlement)

Mandate-bounded promises to pay `ratePerSecond` from
`payer.namespaceFromPayer` to `recipient` across `[startedAt,
endsAt)`. Token entry points delegate to `RivierStreamRegistry`:

| Function | Semantics |
|---|---|
| `openStream(p)` | Returns deterministic `streamRef`. Mandate verified, KYA checked, per-stream slot reserved. |
| `withdrawFromStream(streamRef, amount)` | Pull accrued. Auto-pause check runs first (KYA revoked / cap hit / sanctions / velocity). |
| `closeStream(streamRef)` | Payer or recipient. Future accrual stops. |
| `streamBalance(streamRef) view` | Currently-accrued, unwithdrawn. |

Auto-pause invariants live in the registry's `pauseStream`
callback (POLICY_HOOK_ROLE-gated). Paused streams record the
`RefusalReason` so the recipient surfaces it in their UI without
re-running the policy chain.

### `dryRun` — load-bearing agent introspection

`dryRun(input) view returns DryRunResult` simulates the same check
chain as `transferWithMandate` but state-read-only. Returns the
same `(RefusalReason, ctx)` byte-for-byte that the live path would
revert with. **The byte-equivalence invariant is the load-bearing
agent guarantee**: agents simulate before committing; a simulator
that diverges from the live path is worse than no simulator at all.

Tested via `RivierDryRunEquivalence.t.sol` — for every refusal
case in `RivierRefusalReasons.t.sol`, the test captures the live
revert via `try/catch (bytes memory)` + ABI-decode of the
`RivierRefused(reason, ctx)` selector, then asserts
`dryRun(...).reason == liveR && dryRun(...).ctx == liveCtx`.

## RefusalReason ontology

Every refusal-path revert carries `RivierRefused(reason, ctx)`
where `ctx` is a structured field (mandate ID, address, asset,
etc. depending on reason). Enum values:

| # | Reason | When |
|---|---|---|
| 0 | `OK` | Sentinel, never reverted |
| 1 | `KYA_INVALID` | Credential not active in `KyaRegistry` |
| 2 | `KYA_EXPIRED` | Credential expiry passed |
| 3 | `KYA_REVOKED` | Credential explicitly revoked |
| 4 | `MANDATE_EXPIRED` | Past mandate `expiresAt`, OR before `notBefore` |
| 5 | `MANDATE_PER_TX_CAP` | Single-leg notional > `maxPerItemUsd` |
| 6 | `MANDATE_CUMULATIVE_CAP` | Projected cumulative spend > `maxTotalUsd` |
| 7 | `MANDATE_ASSET_NOT_ALLOWED` | Asset not in mandate's allowlist |
| 8 | `MANDATE_PRINCIPAL_MISMATCH` | Caller doesn't match mandate principal (sub-cases: zero-address, wrong signer) |
| 9 | `MANDATE_REVOKED` | Mandate explicitly revoked OR replayed nonce |
| 10 | `MANDATE_SIGNATURE_INVALID` | EIP-712 principal sig doesn't recover |
| 11 | `MANDATE_AGENT_SIGNATURE_INVALID` | EIP-712 agent sig doesn't recover |
| 12 | `JURISDICTION_GATE` | Reserved post-launch (stub returns OK) |
| 13 | `TRAVEL_RULE_BLOCK` | PolicyHook denied (e.g. self-hosted >$10k without attestation) |
| 14 | `SANCTIONS_HIT` | Chainalysis oracle returned `true` for from/to |
| 15 | `POR_STALE` | PoR feed older than 24h |
| 16 | `POR_INSUFFICIENT` | Reserves below circulating + projected mint |
| 17 | `PERMISSIONED_RWA` | Reserved post-launch |
| 18 | `PAUSED` | Token paused, OR caller invoked a post-launch stub |
| 19 | `NAMESPACE_INSUFFICIENT` | `from`'s `namespace` doesn't have `amount` to debit |

## Role separation

| Role | Holder | What it can do |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Treasury multisig | Manage MINTER / BURNER / PAUSER / RECOVERY. **Not** CCIP admin. |
| `MINTER_ROLE` | CCIP `BurnMintTokenPool` + treasury | `mint(addr, amount)` |
| `BURNER_ROLE` | CCIP `BurnMintTokenPool` | `burn(amount)` / `burnFrom(addr, amount)` |
| `PAUSER_ROLE` | Pauser multisig (incident response) | `pause()` / `unpause()` |
| `CCIP_ADMIN_ROLE` | Cross-chain ops multisig (separate from DEFAULT_ADMIN) | `transferCCIPAdmin`, `setPorFeed`, registry rewires |
| `RECOVERY_ROLE` | Recovery key multisig | `revokeAllMandates(principal)` (used during MPC compromise recovery) |

The deploy script enforces `CCIP_ADMIN != DEFAULT_ADMIN` at
broadcast time. The lesson from the Apr 2026 KelpDAO exploit
(~$290M, 1-of-1 LZ DVN) — even if the CCIP-admin multisig is
breached, the attacker can rebind the pool but cannot mint or
pause RIVR. Conversely, even a compromised treasury cannot
unilaterally rewire the cross-chain config.

## PolicyHook posture — upgradable until freeze

`RivierPolicyHook` is upgradable via 7-day timelock + 5-of-9
multisig (3 Rivier core / 2 custodian / 1 auditor / 1 legal /
1 Tenzro / 1 community). It freezes — irreversibly — when:

- Audit clean by Trail of Bits / OpenZeppelin / Spearbit class, AND
- ($500M circulating supply OR 18 months continuous mainnet operation)

Post-freeze, `PolicyHook` becomes immutable; sub-oracle slots
(jurisdiction / velocity / counterparty / RWA gate) become the
upgradable surface behind 30-day timelock. Do NOT add upgrade
paths that route around the freeze milestone.

## CCIP CCT registration

This token is CCT-compatible (CCIP v1.5+, mainnet GA Apr 2026).
Registration is permissionless / self-serve.

### Per-chain TokenAdminRegistry addresses (verify in
[chain.link/ccip directory](https://docs.chain.link/ccip/directory)
before broadcasting — addresses change on chain upgrades):

- Ethereum mainnet:  `0xb22764f98dD05c789929716D677382Df22C05Cb6`
- Base mainnet:       `0x6f6C373d09C07425BaAE72317863d7F6bb731e37`
- Arbitrum One:       `0x39AE1032cF4B334a1Ed41cdD0833bdD7c7E7751E`
- Optimism:           `0x657c42abe4caf8d1b6e9c10ec1f3fbe3f0c46b8c`
- Polygon PoS:        `0x00f027eA9D32A3c8E72cA4FBce5E32F4cD5A89B6`

### Deploy runbook (per chain)

**Prerequisites**:
1. Two distinct multisigs deployed: `DEFAULT_ADMIN` (treasury) and
   `CCIP_ADMIN` (cross-chain ops). MUST be different addresses.
2. Real Chainlink `BurnMintTokenPool` deployed from
   `@chainlink/contracts-ccip/src/v0.8/ccip/pools/BurnMintTokenPool.sol`.
   **Do NOT ship the local scaffold pool to mainnet** — it's a
   test-only stand-in with no DON attestation, no OffRamp/OnRamp
   wiring, no RMN integration.
3. PoR feed address from Chainlink (optional at deploy; can be
   wired post-deploy via `setPorFeed` from the CCIP admin).
4. Deployer wallet funded with native gas + headroom for register
   txs + `setPool` + `applyChainUpdates` per remote lane.

**Step 1 — deploy + register**:

```bash
cd contracts

# Optional: dry-run, no broadcast.
DEFAULT_ADMIN=0x...      \
MINTER=0x...             \
PAUSER=0x...             \
CCIP_ADMIN=0x...         \
RECOVERY=0x...           \
TOKEN_ADMIN_REGISTRY=0x... \
POOL_ADDR=0x...          \
POR_FEED=0x...           \  # optional; testnet leaves unset
OUTBOUND_CAPACITY=$((1000000 * 10**18))  \
OUTBOUND_RATE=$((100 * 10**18))          \
INBOUND_CAPACITY=$((1000000 * 10**18))   \
INBOUND_RATE=$((100 * 10**18))           \
PRIVATE_KEY=0x...        \
forge script script/DeployRivierCCT.s.sol:DeployRivierCCT \
  --rpc-url $RPC_URL

# Broadcast for real.
... --broadcast --verify
```

The script:
1. Deploys `RivierKyaRegistry`, `RivierMandateRegistry`,
   `RivierStreamRegistry`, `RivierPolicyHook`, `RivierTokenCCT`.
2. Wires the four registries into the token via setters.
3. Grants `MINTER_ROLE` + `BURNER_ROLE` on the token to the pool.
4. Calls `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin(token)`
   on the chain's CCIP registry module (NOT direct `proposeAdminRole` —
   self-serve flow uses the getCCIPAdmin path).
5. From CCIP_ADMIN: `tokenAdminRegistry.acceptAdminRole(token)` then
   `setPool(token, pool)`.
6. Validates `CCIP_ADMIN != DEFAULT_ADMIN` and (on mainnet) emits a
   warning if `POR_FEED == address(0)`.

**Step 2 — per-lane wiring (after deploy on both source + dest)**:

To actually move tokens between two chains, each pool needs to know
about the other side's pool/token + a per-remote rate limit:

```solidity
pool.applyChainUpdates([{
  remoteChainSelector: <selector-of-other-chain>,
  allowed: true,
  remotePoolAddress: abi.encode(<other-chain-pool>),
  remoteTokenAddress: abi.encode(<other-chain-RIVR>),
  outboundRateLimiterConfig: { isEnabled: true, capacity: ..., rate: ... },
  inboundRateLimiterConfig:  { isEnabled: true, capacity: ..., rate: ... }
}]);
```

Run **for each destination chain** RIVR launches on, on **both ends**.

### Verify post-deploy

```bash
# CCIP registry shows correct admin + pool
cast call $TOKEN_ADMIN_REGISTRY \
  "getTokenConfig(address)(address,address,address)" \
  $RIVR_TOKEN --rpc-url $RPC_URL
# Expected: (CCIP_ADMIN, 0x0, POOL_ADDR)

cast call $RIVR_TOKEN "getCCIPAdmin()(address)" --rpc-url $RPC_URL
# Expected: $CCIP_ADMIN

# Pool has MINTER + BURNER on the token
cast call $RIVR_TOKEN "hasRole(bytes32,address)(bool)" \
  $(cast keccak "MINTER_ROLE") $POOL_ADDR --rpc-url $RPC_URL
cast call $RIVR_TOKEN "hasRole(bytes32,address)(bool)" \
  $(cast keccak "BURNER_ROLE") $POOL_ADDR --rpc-url $RPC_URL

# Registries wired
cast call $RIVR_TOKEN "kyaRegistry()(address)" --rpc-url $RPC_URL
cast call $RIVR_TOKEN "mandateRegistry()(address)" --rpc-url $RPC_URL
cast call $RIVR_TOKEN "streamRegistry()(address)" --rpc-url $RPC_URL
cast call $RIVR_TOKEN "policyHook()(address)" --rpc-url $RPC_URL
```

### Rate limit policy

Defaults in `DeployRivierCCT.s.sol` are conservative mainnet-launch
numbers:

| Side     | Capacity (per refill window) | Rate     |
|----------|------------------------------|----------|
| Outbound | 1,000,000 RIVR               | 100/sec  |
| Inbound  | 1,000,000 RIVR               | 100/sec  |

Bucket-based: capacity = max single-tx size, rate = refill speed. At
100/sec, a fully drained 1M bucket refills in ~10,000 seconds (~2.8 h).
Tighten further if launch volume is low — easier to loosen later than
to discover an attestation flaw under unbounded drain. Raises require
multisig timelock; lowers should be immediate for incident response.

## Test commands

The launch test suite is 113 tests across 8 files. Skip flags
exclude broken sibling contracts (loyalty / drop / membership /
randomness — pre-existing import resolution failures that don't
affect rivier-token):

```bash
cd contracts

# Full launch suite — 113 tests
forge test --match-path "test/rivier-token/**" \
  --skip "src/drop/**" --skip "src/loyalty/**" \
  --skip "src/membership/**" --skip "src/randomness/**" -vv

# Per-file:
# RivierKyaRegistry           —  8 tests   (sync + revoke + staleness)
# RivierMandateRegistry       — 13 tests   (cumulative spend + revocation + reentrancy)
# RivierPolicyHook            — 11 tests   (sanctions + Travel Rule + timelock guard)
# RivierStreamAutoPause       — 24 tests   (accrual + auto-pause invariants + edge cases)
# RivierTokenLaunch           — 22 tests   (happy paths for every Launch surface)
# RivierRefusalReasons        — 15 tests   (one per RefusalReason enum case)
# RivierNamespaceInvariants   — 10 tests   (incl. 2 fuzz tests at 256 runs)
# RivierDryRunEquivalence     — 10 tests   (byte-equivalence: dryRun ≡ live revert)

# Gas snapshot
forge snapshot --match-path "test/rivier-token/RivierTokenLaunch.t.sol" \
  --skip "src/drop/**" --skip "src/loyalty/**" \
  --skip "src/membership/**" --skip "src/randomness/**"
# Sanity: transferWithMandate < 200k gas; batch 100-leg < 30k gas/leg;
# withdrawFromStream < 100k gas.
```

## Reference

- Design doc: `docs/architecture/2026-rivr-design.md`
- Chainlink CCT docs: https://docs.chain.link/ccip/concepts/cross-chain-tokens
- TokenAdminRegistry source:
  https://github.com/smartcontractkit/ccip/blob/main/contracts/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol
- BurnMintTokenPool source:
  https://github.com/smartcontractkit/ccip/blob/main/contracts/src/v0.8/ccip/pools/BurnMintTokenPool.sol
- Per-chain registry addresses + selectors:
  https://docs.chain.link/ccip/directory
- ERC-6909 (architectural reference for namespaces):
  https://eips.ethereum.org/EIPS/eip-6909
- Sablier Flow (architectural reference for streams, GPL — not vendored):
  https://github.com/sablier-labs/flow
- ERC-3643 (architectural reference for KYA registry, GPL — not vendored):
  https://github.com/TokenySolutions/T-REX
