# RIVR

Reference implementation of an AI- and agent-native programmable stablecoin.

**Status**: pre-launch / testnet. Independent contributor project. Audit not yet
commissioned (OpenZeppelin / Trail of Bits / Spearbit class — engagement
discussions in progress).

## What this is

RIVR is the first stablecoin where mandate validation, agent attestation,
programmable batching, and continuous settlement streams are token-contract
primitives — not orchestration above an inert ERC-20.

The differentiator is the *composition*: every primitive below is a
load-bearing call on a single token contract, dispatched from one EIP-712
mandate envelope, with a single typed `RefusalReason` revert surface and a
byte-equivalent `dryRun` view that lets agents introspect a leg before
submitting it on-chain.

| Primitive | Surface |
|---|---|
| Mandate-bound transfer | `transferWithMandate(to, amount, mandate, intentClass, memoHash)` — EIP-712 envelope verified inline (principal sig + EIP-1271 fall-through, agent sig, KYA registry, expiry, per-tx cap, asset allowlist, cumulative cap, PolicyHook). |
| Programmable batching | `batchProgrammableTransfer(...)` — single mandate covers N legs, sum-checked once against cumulative cap, atomic, one event per leg with shared `transferRef = batchRef ^ legIndex`. |
| Continuous settlement streams | `openStream` / `withdrawFromStream` / `closeStream` / `streamBalance` — accrual-tracked, PolicyHook-gated, auto-paused on KYA revoke / cumulative cap hit / sanctions hit. |
| Sub-balance namespaces | Solady ERC-6909 storage. `balanceOf(holder)` is the sum across namespaces; intra-namespace moves don't emit `Transfer`. |
| Agent attestation | Versioned `ProgrammableTransferEvent.extensionData` (v1 carries model id, version, confidence, reasoningHash, promptHash, mcpServerDid, teeAttestationHash, policyComplianceProof). |
| Dry-run introspection | `dryRun(input) view` — walks the same check chain as `transferWithMandate`, returns `RefusalReason` byte-for-byte. The load-bearing agent-introspection guarantee. |

## Repo layout

```
contracts/
  src/rivier-token/
    RivierTokenCCT.sol            — token contract (~1.6k lines)
    types/                        — MandateEnvelope, RefusalReason, IntentClass, StreamParams, BatchMetadata, DryRunInput, DryRunResult
    interfaces/                   — IBurnMintERC20, IGetCCIPAdmin, IPoRFeed, IRivierKyaRegistry, IRivierMandateRegistry, IRivierStreamRegistry, IPolicyHook, IChainalysisSanctionsList, ITokenAdminRegistry, IRateLimiter
    registries/                   — RivierKyaRegistry, RivierMandateRegistry, RivierStreamRegistry
    policy/                       — RivierPolicyHook
    README.md                     — operator runbook
  script/
    DeployRivierCCT.s.sol         — Foundry registration script (CCT proposeAdminRole / acceptAdminRole / setPool / applyChainUpdates)
  test/rivier-token/              — 189 forge tests
  foundry.toml
docs/
  design/rivr.md                  — design summary (Executive Summary; full implementation doc is private to the operating team)
LICENSE                           — MIT
```

## Test suite

189 tests across 11 files. The suite is exhaustive on the load-bearing
invariants the design doc names:

| File | Tests | Focus |
|---|---|---|
| `RivierTokenLaunch.t.sol` | 22 | Happy paths for every launch surface (transferWithMandate / batch / stream / namespace / dryRun) |
| `RivierRefusalReasons.t.sol` | 15 | One test per refusal class — typed revert + ctx field |
| `RivierDryRunEquivalence.t.sol` | 10 | `dryRun(input).reason == liveRevert.reason` byte-for-byte across every refusal path |
| `RivierNamespaceInvariants.t.sol` | 10 (incl. 2 fuzz × 256 runs) | `balanceOf(holder) == sum(balanceOfNamespace(holder, ns))` |
| `RivierStreamAutoPause.t.sol` | 24 | Accrual correctness; auto-pause on KYA revoke / cumulative cap / sanctions; mid-stream withdraw + close edge cases |
| `RivierMandateRegistry.t.sol` | 13 | Cumulative spend tracking; reentrancy safety; revoke-by-principal; recovery-revoke-all |
| `RivierKyaRegistry.t.sol` | 8 | Sync-wallet permissioning; staleness; revocation propagation |
| `RivierPolicyHook.t.sol` | 11 | Sanctions oracle integration (mocked Chainalysis); pass-through stubs return OK; timelock guard on `setSanctionsOracle` |
| `RivierTokenBranchCoverage.t.sol` | 48 | Direct branch coverage on `RivierTokenCCT.sol` (constructor guards, `_update`, PoR scaling, registry setters, namespace ops, batch validation, stream pre-validation, dryRun branches) |
| `RivierPolicyHookBranchCoverage.t.sol` | 17 | Direct branch coverage on `RivierPolicyHook.sol` (constructor, sub-oracle setters, `checkBatch` per-leg failure with leg-index-in-ctx) |
| `RivierTypeHelpersCoverage.t.sol` | 11 | `MandateEnvelopeLib.assetAllowed` sentinel + explicit branches; `IntentClasses.unwrap` / `eq` |

### Coverage

Run with the same skip flags as the main suite (sibling contracts are not
part of the RIVR token surface):

```bash
cd contracts
forge coverage --match-path "test/rivier-token/**" \
  --skip "src/drop/**" --skip "src/loyalty/**" \
  --skip "src/membership/**" --skip "src/randomness/**" \
  --ir-minimum --report summary
```

Current state:

| File | Lines | Statements | Funcs |
|---|---|---|---|
| `RivierTokenCCT.sol` | 95.59% | 95.17% | 97.56% |
| `RivierPolicyHook.sol` | 100.00% | 100.00% | 100.00% |
| `RivierKyaRegistry.sol` | 96.77% | 96.77% | 100.00% |
| `RivierMandateRegistry.sol` | 98.25% | 96.55% | 100.00% |
| `RivierStreamRegistry.sol` | 100.00% | 95.51% | 100.00% |
| `IntentClass.sol` | 100.00% | 100.00% | 100.00% |
| `MandateEnvelope.sol` | 64.71%* | 65.38%* | 100.00% |
| **Total** | **96.45%** | **95.13%** | **98.92%** |

\*`MandateEnvelope.sol` line/statement metrics are suppressed because
`_hashAddressArray` is implemented in inline assembly (gas-critical
path); forge coverage cannot instrument assembly. Branches and funcs
on the same file are 100%.

The repo-level branch metric reads ~42% under `--ir-minimum`. This is
a known LCOV-instrumentation gap when forge is run against contracts
that require `--ir-minimum` to compile (RivierTokenCCT trips the stack
limit without it): BRDA records emit `hits=-` for legs that the
instrumented bytecode can't trace back to a single source-level branch,
and `forge coverage --report summary` counts those as zero. The branch
*paths* are exercised — see `RivierTokenBranchCoverage.t.sol` (48
direct-branch tests) and `RivierPolicyHookBranchCoverage.t.sol` (17).

### Running

```bash
cd contracts
forge test --match-path "test/rivier-token/**" \
  --skip "src/drop/**" --skip "src/loyalty/**" \
  --skip "src/membership/**" --skip "src/randomness/**" -vv
```

The `--skip` flags exclude unrelated sibling contracts (loyalty / drop /
membership / randomness) that are not part of the RIVR token surface and
have their own dependency requirements.

For gas snapshots of the launch surface:

```bash
forge snapshot --match-path "test/rivier-token/RivierTokenLaunch.t.sol"
```

Sanity targets: `transferWithMandate < 200k gas`,
`batchProgrammableTransfer 100-leg batch < 30k gas/leg`,
`withdrawFromStream < 100k gas`.

## Threat model

This section frames how the contracts are intended to be used and the
adversaries / failure modes they're designed against. It is the
load-bearing context for any audit engagement.

### Trust assumptions

- **Mandate principal signature is authoritative.** A leg can spend
  RIVR on the principal's behalf only if the EIP-712 envelope carries
  a valid principal signature (with EIP-1271 fall-through for smart
  accounts via OpenZeppelin's `SignatureChecker`). Compromise of the
  principal's signing key is out of scope at the contract layer; it
  is mitigated off-chain by Rivier's MPC/4337 stack and the recovery
  role on `RivierMandateRegistry`.
- **KyaSyncWorker is honest.** The on-chain `RivierKyaRegistry` mirrors
  W3C VCs from `did:web:identity.rivier.ai` under a multisig
  KYA_SYNC_ROLE. Token transfers consult the registry inline. The
  worker is operationally trusted to keep the on-chain state ≤60s P95
  behind the canonical VC. A malicious worker could forge KYA validity;
  that is treated as an operational/key-management failure, not a
  contract bug.
- **PolicyHook is upgradable behind a 7-day timelock until milestone
  freeze.** The hook becomes immutable when the audit lineage is
  clean AND ($500M circulating supply OR 18 months continuous mainnet
  operation). Post-freeze, only sub-oracle slots (jurisdiction /
  velocity / counterparty / RWA) remain upgradable behind a 30-day
  timelock.
- **Chainalysis sanctions oracle is read-only and authoritative.** On
  chains where Chainalysis hasn't shipped, the oracle slot is
  `address(0)` and the on-chain sanctions check short-circuits to
  "not sanctioned"; off-chain enforcement at the API gateway covers
  those lanes. This is documented as a known operational dependency
  rather than a contract guarantee.
- **CCIP `BurnMintTokenPool` is the only mint/burn caller** (other
  than the test harness). MINTER_ROLE / BURNER_ROLE are granted to
  the pool. Compromise of the pool is a CCIP failure mode, not a
  RIVR failure mode.
- **CCIP_ADMIN_ROLE is a multisig** (deploy-script invariant: must
  not equal DEFAULT_ADMIN_ROLE). One-of-one EOA admin is the failure
  mode that drained KelpDAO; the deploy script enforces the role
  split at validation time.

### Adversaries the contracts must defend against

1. **Replay of a signed envelope across mandates.** Defended by the
   one-shot nonce in `MandateEnvelope` and `RivierMandateRegistry`'s
   `isRevokedOrExpired` short-circuit on already-revoked mandates.
   `recordMandateUse` rejects subsequent uses where the binding
   image (principal / agent / kyaCredentialHash / maxTotalUsd /
   expiresAt) does not exactly match the one registered on first use.
2. **Reentrancy into `recordMandateUse` to inflate cumulative spend.**
   Defended by CEI: the token updates balances FIRST, then calls
   into the registry. The registry holds no native value, so no
   reentrancy guard is required. Verified by
   `RivierMandateRegistry.t.sol` (13 tests).
3. **Namespace drain via cross-namespace debit.** Defended by Solady
   ERC-6909 isolation — `_namespaceDebit(holder, ns, amount)` only
   touches `(holder, ns)`. Sum-preservation invariant is fuzzed at
   256 runs in `RivierNamespaceInvariants.t.sol`.
4. **Stream over-withdrawal.** Defended by `_accruedBalance` reading
   `min(now, endsAt) - startedAt` (with paused-time exclusion) on
   every withdraw. The registry holds no float; the token's
   namespace bookkeeping is the source of truth. Verified by
   `RivierStreamAutoPause.t.sol` (24 tests).
5. **Mandate cap evasion via batch.** Defended by single-mandate-per-
   batch + sum-of-amounts checked once against the cumulative cap
   in `batchProgrammableTransfer`.
6. **Travel Rule bypass via amount-just-below-de-minimis splitting.**
   Defended at the policy layer (off-chain rivier-policy correlates
   legs by mandate). On-chain, the de minimis is the FATF $1k
   default; aggregate-evasion is treated as a policy-engine concern,
   not a contract concern.
7. **Stale Proof-of-Reserve mint.** Defended by `_checkReserve`'s 24h
   staleness window + non-positive-answer guard + scaled-decimal
   supply check. `setPorFeed(address(0))` short-circuits the gate
   for testnet; mainnet deploys MUST set the feed.
8. **Cross-chain mint via compromised CCIP pool.** Out of scope at
   the RIVR layer — that's a CCIP rail compromise. Defense at the
   rail layer (DON + RMN + per-lane rate limits) is Chainlink's,
   not ours. Per-lane rate limits applied via `applyChainUpdates`
   in the deploy script provide the bound on blast radius even if
   the off-ramp is compromised.

### Out of scope (operational, not contract-level)

- Off-chain Notabene Travel Rule envelope construction and signing.
- KYA VC issuance and the `did:web:identity.rivier.ai` private key.
- MPC threshold signing and recovery-share custody (Phase Y / Z).
- The PolicyHook's pass-through stubs (jurisdiction / velocity /
  counterparty / RWA) — they return `OK` at launch by design.
- Service-side rewires (rivier-transaction / rivier-curator /
  rivier-batch / rivier-policy / rivier-mcp) — these are off-chain
  callers that consume the on-chain ABI; their correctness is the
  service-layer audit's concern, not the contract audit's.

## Load-bearing invariants

These are explicitly tested and must hold across every public path:

1. **`dryRun(input).reason == liveRevert.reason` byte-for-byte.**
   `RivierDryRunEquivalence.t.sol` covers every `RefusalReason` enum
   value. This is the agent-introspection guarantee — agents must be
   able to ask "would this leg succeed?" and get the same answer the
   chain would give.
2. **`balanceOf(holder) == sum(balanceOfNamespace(holder, ns))` for
   all `holder`.** Fuzzed at 256 runs.
3. **Cumulative spend monotonically increases.** Cannot be reset
   without `revokeMandate` (which terminates the mandate) or
   `revokeAllMandates` (RECOVERY_ROLE-gated).
4. **Stream auto-pause is sufficient** — KYA revoke / mandate cap hit
   / sanctions hit MUST pause; recipient cannot withdraw past the
   pause point. Verified across 24 tests.
5. **Mandate registry first-use lazy registration is binding.** Once
   `recordMandateUse` registers the metadata, subsequent uses MUST
   match exactly or revert with `ImmutableFieldChanged`.
6. **CCIP_ADMIN_ROLE != DEFAULT_ADMIN_ROLE.** Enforced by the deploy
   script (validation step before broadcast).

## Role inventory

| Role | Holder | Purpose |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | RIVR governance multisig | Grants/revokes other roles |
| `MINTER_ROLE` | CCIP `BurnMintTokenPool` | Inbound mint on cross-chain delivery |
| `BURNER_ROLE` | CCIP `BurnMintTokenPool` | Source-side burn |
| `PAUSER_ROLE` | RIVR governance multisig | Emergency pause |
| `CCIP_ADMIN_ROLE` | RIVR governance multisig (must differ from DEFAULT_ADMIN) | `getCCIPAdmin` / `transferCCIPAdmin` per CCT |
| `RECOVERY_ROLE` | Principal's recovery share | `revokeAllMandates(principal)` |
| `TOKEN_ROLE` (registries) | RIVR token contract | Sole authoriser of `recordMandateUse`, `openStream`, `withdrawFromStream`, `closeStreamFor` |
| `POLICY_HOOK_ROLE` (StreamRegistry) | PolicyHook contract | Auto-pause callbacks |
| `KYA_SYNC_ROLE` (KyaRegistry) | rivier-identity multisig sync wallet | Mirror W3C VCs to on-chain registry |
| `POLICY_ADMIN_ROLE` (PolicyHook) | 7-day timelock contract | `setKyaRegistry` / `setSanctionsOracle` |
| `TRAVEL_RULE_ATTESTOR_ROLE` (PolicyHook) | rivier-policy service | `markTravelRuleAttested(hash)` |

## Deployment

See `contracts/src/rivier-token/README.md` for the per-chain operator
runbook and `contracts/script/DeployRivierCCT.s.sol` for the registration
script. The flow is permissionless self-serve under CCIP v1.5+ CCT and
does not require Chainlink Labs approval. The script enforces the
`CCIP_ADMIN_ROLE != DEFAULT_ADMIN_ROLE` invariant at validation time
before broadcasting.

For audit firms: a structured `deployment.md` with reproducible
testnet / forked-mainnet steps is in preparation as a separate document.

## Known limitations

1. **`MandateEnvelope._hashAddressArray` uses inline assembly** for the
   keccak256 of the dynamic `assetAllowlist` array. This is gas-critical
   (called from `structHash` on every `transferWithMandate`) and
   forge-coverage cannot instrument it; line/statement metrics on
   `MandateEnvelope.sol` reflect this. The branches and external
   wrappers (`assetAllowed`, `structHash`) are 100% covered by
   `RivierTypeHelpersCoverage.t.sol`.
2. **PolicyHook pass-through stubs return `OK`.** Jurisdiction / velocity
   / counterparty / RWA gates are slots reserved for post-launch
   hardening behind a 30-day timelock. The launch claim does not
   include these as enforced gates.
3. **Sanctions oracle slot may be `address(0)`** on chains without
   Chainalysis coverage (Base at deploy time, etc.). On-chain check
   short-circuits; off-chain enforcement applies until Chainalysis
   publishes the lane.
4. **Stream `closeStream` truncates `endsAt` in place** rather than
   marking the stream terminal. Existing accrued-but-not-withdrawn
   balance remains drawable until next sweep. Re-open of a closed
   stream's deterministic `streamRef` is rejected by
   `StreamAlreadyExists`. The `StreamClosedError` typed error is
   reserved for a post-launch terminal-state path.
5. **`projectCumulative` returns the projected total even when it
   exceeds the cap.** The view's role is to inform; the cap-enforcement
   decision is the caller's. This is the same surface `dryRun` uses
   to compute the cumulative-cap branch.
6. **Travel Rule de minimis is hardcoded to FATF $1k** in
   `RivierPolicyHook.sol` (`TRAVEL_RULE_DE_MINIMIS_USD6`). Per-
   jurisdiction thresholds are enforced off-chain at rivier-policy.

## Contributions and standards work

The RIVR design is being submitted to standards venues. Live submissions:

- x402 Foundation: discussion at [x402-foundation/x402#2176](https://github.com/x402-foundation/x402/issues/2176), draft spec PR at [x402-foundation/x402#2175](https://github.com/x402-foundation/x402/pull/2175).
- AP2 / FIDO Alliance: sample/SDK alignment discussion at [google-agentic-commerce/AP2#255](https://github.com/google-agentic-commerce/AP2/issues/255).

The same constraint envelope is rail-agnostic; submissions to fiat-rail
venues (Visa TAP, Mastercard agent-pay, ISO 20022 agentic-payment work,
IETF, W3C, FIDO/WebAuthn) are sequenced after the on-chain spec lands.

## License

MIT — see [LICENSE](LICENSE).
