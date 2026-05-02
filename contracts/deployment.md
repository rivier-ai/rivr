# Deployment runbook

Audit-firm-facing reference for how the RIVR launch suite deploys to
mainnet, what addresses an auditor will see post-broadcast, and which
invariants gate the deployment.

This document covers the **deployment posture** — the role
separation, the registration sequencing, the post-deploy verification
contract, and the rate-limit policy. The Foundry deploy script
(`script/DeployRivierCCT.s.sol`) is held in the operator-only mirror
and is not vendored to this public repo. Auditors who need to run the
script as part of the engagement can request it under NDA via
`security@rivier.ai`.

## Scope

Per-chain deploy lands the following five contracts in one transaction
sequence, then registers the token with Chainlink CCIP's
`TokenAdminRegistry` and wires per-lane rate limits:

1. `RivierKyaRegistry` — on-chain mirror of KYA VCs.
2. `RivierMandateRegistry` — mandate state + cumulative spend tracker.
3. `RivierStreamRegistry` — continuous-settlement streams.
4. `RivierPolicyHook` — KYA + sanctions + Travel Rule oracle wiring.
5. `RivierTokenCCT` — the launch RIVR token (this is what users hold).

After this sequence, three CCIP registration calls bind the token to
the Chainlink cross-chain rail:

6. `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin(token)` —
   permissionless self-serve registration.
7. `TokenAdminRegistry.acceptAdminRole(token)` — from `CCIP_ADMIN`.
8. `TokenAdminRegistry.setPool(token, pool)` — from `CCIP_ADMIN`.

Per-lane wiring (`pool.applyChainUpdates(...)`) runs separately on
each side after deploys complete on both source and destination.

## Prerequisites

### Multisigs (MUST be deployed before broadcast)

| Role | Holder | Purpose |
|---|---|---|
| `DEFAULT_ADMIN_ROLE` | Treasury multisig | Manages MINTER / BURNER / PAUSER / RECOVERY. **Must NOT** also hold `CCIP_ADMIN_ROLE`. |
| `CCIP_ADMIN_ROLE` | Cross-chain ops multisig | Manages CCIP admin handoff, registry rewires, PoR feed. **Must be a different address** from `DEFAULT_ADMIN`. |
| `MINTER_ROLE` | CCIP `BurnMintTokenPool` + treasury | `mint(addr, amount)`. The pool address is granted in step 3 of the deploy sequence. |
| `BURNER_ROLE` | CCIP `BurnMintTokenPool` | `burn(amount)` / `burnFrom(addr, amount)`. |
| `PAUSER_ROLE` | Pauser multisig (incident response) | `pause()` / `unpause()`. Often distinct from treasury and CCIP-admin. |
| `RECOVERY_ROLE` | Recovery key multisig | `revokeAllMandates(principal)`. Used during MPC compromise recovery only. |

**Boot invariant**: the deploy script reverts if `CCIP_ADMIN ==
DEFAULT_ADMIN`. The lesson from the Apr 2026 KelpDAO exploit (~$290M
drained via 1-of-1 LayerZero DVN) is that **even if one multisig is
breached, the attacker should not be able to compromise the other
domain**. With the role split:

- A compromised treasury cannot rewire the cross-chain config.
- A compromised CCIP-admin multisig cannot mint, pause, or revoke
  mandates — only rebind the pool.

Auditors should verify post-deploy that the two multisigs resolve to
non-equal addresses on every chain (see [Verify post-deploy](#verify-post-deploy)).

### Chainlink dependencies

| Dependency | Source | Notes |
|---|---|---|
| `BurnMintTokenPool` | `@chainlink/contracts-ccip/src/v0.8/ccip/pools/BurnMintTokenPool.sol` | **Real Chainlink pool, not the local scaffold.** The repo's `RivierBurnMintTokenPool.sol` scaffold is for forge tests only — it has no DON attestation, no OffRamp/OnRamp wiring, no RMN. Mainnet broadcasts MUST set `POOL_ADDR` to a real Chainlink-deployed pool. |
| `TokenAdminRegistry` | Per-chain (see addresses below) | Verified against [chain.link/ccip/directory](https://docs.chain.link/ccip/directory) at deploy time — addresses change on chain upgrades, do not hardcode without re-verifying. |
| `RegistryModuleOwnerCustom` | Per-chain (paired with `TokenAdminRegistry`) | The self-serve registration entry point. Resolves the calling token's `getCCIPAdmin()` to determine who can accept the admin role. |
| Proof-of-Reserve feed | Chainlink PoR | Optional at deploy. Can be wired post-deploy via `setPorFeed` from the CCIP admin multisig. Mainnet without PoR feed emits a deploy-time warning but is not a hard failure (the PoR gate short-circuits when `porFeed == address(0)`). |

### Per-chain `TokenAdminRegistry` addresses

Verified against `docs.chain.link/ccip/directory` at the time of the
contract README (May 2026). **Re-verify before broadcast** — Chainlink
rotates these on chain upgrades.

| Chain | TokenAdminRegistry |
|---|---|
| Ethereum mainnet | `0xb22764f98dD05c789929716D677382Df22C05Cb6` |
| Base mainnet | `0x6f6C373d09C07425BaAE72317863d7F6bb731e37` |
| Arbitrum One | `0x39AE1032cF4B334a1Ed41cdD0833bdD7c7E7751E` |
| Optimism | `0x657c42abe4caf8d1b6e9c10ec1f3fbe3f0c46b8c` |
| Polygon PoS | `0x00f027eA9D32A3c8E72cA4FBce5E32F4cD5A89B6` |

## Environment contract

The deploy script reads the following environment variables. Auditors
reviewing a broadcast log will see these encoded in the constructor
arguments + post-deploy role grants.

| Var | Required | Type | Meaning |
|---|---|---|---|
| `DEFAULT_ADMIN` | Yes | address | Recipient of `DEFAULT_ADMIN_ROLE` on all 5 contracts. Treasury multisig. |
| `MINTER` | Yes | address | Receives `MINTER_ROLE` on the token. Typically the treasury multisig at deploy time; the CCIP pool is granted minter separately in step 3. |
| `PAUSER` | Yes | address | Receives `PAUSER_ROLE` on the token. |
| `CCIP_ADMIN` | Yes | address | Receives `CCIP_ADMIN_ROLE`. **Reverts if equal to `DEFAULT_ADMIN`.** |
| `RECOVERY` | Yes | address | Receives `RECOVERY_ROLE` on the mandate registry. |
| `TOKEN_ADMIN_REGISTRY` | Yes | address | Per-chain Chainlink registry — see table above. |
| `POOL_ADDR` | Yes (mainnet) | address | Real Chainlink `BurnMintTokenPool`. Deploy fails on mainnet if unset; testnet allows the local scaffold for end-to-end forge testing. |
| `POR_FEED` | No | address | Chainlink Proof-of-Reserve aggregator. Leave unset on testnet; **set on mainnet** before high-volume issuance. Mainnet without PoR feed emits a warning event but is not blocked. |
| `OUTBOUND_CAPACITY` | Yes | uint256 | Per-lane outbound bucket capacity (RIVR, 18 decimals). See [Rate limit policy](#rate-limit-policy). |
| `OUTBOUND_RATE` | Yes | uint256 | Per-lane outbound refill rate (RIVR/sec). |
| `INBOUND_CAPACITY` | Yes | uint256 | Per-lane inbound bucket capacity. |
| `INBOUND_RATE` | Yes | uint256 | Per-lane inbound refill rate. |
| `PRIVATE_KEY` | Yes | bytes32 | Deployer EOA. Burns at most enough native gas to cover the 8-step sequence + per-lane wiring. |

## Deploy sequence (per chain)

The script executes the steps below atomically per `forge script` run.
A broadcast log will show exactly this ordering — auditors should
match the on-chain transactions against this sequence.

1. **Deploy `RivierKyaRegistry(admin, syncWallet)`**.
   Constructor reverts on either argument being the zero address.
2. **Deploy `RivierMandateRegistry(admin)`**.
3. **Deploy `RivierStreamRegistry(admin)`**.
4. **Deploy `RivierPolicyHook(admin, policyAdmin, kyaRegistry,
   sanctionsOracle)`**.
   Constructor reverts on `admin`, `policyAdmin`, `kyaRegistry` zero
   addresses; `sanctionsOracle` MAY be `address(0)` on chains where
   Chainalysis hasn't shipped (the hook short-circuits that check).
5. **Deploy `RivierTokenCCT(admin, minter, pauser, ccipAdmin,
   recovery, kyaRegistry, mandateRegistry, streamRegistry, policyHook,
   "RIVR", "RIVR")`**.
   Constructor reverts when `ccipAdmin == admin`. Constructor also
   wires the four registry pointers.
6. **Grant TOKEN_ROLE on each registry to the token** so the token
   can call `recordMandateUse`, `openStream`, `withdrawFromStream`,
   `closeStreamFor`. The KYA registry does not require TOKEN_ROLE
   (the token reads via `isValid` view-only).
7. **Grant POLICY_HOOK_ROLE on the stream registry to the policy
   hook** so the hook can `pauseStream` on KYA-revoked / sanctions /
   cap-hit signals.
8. **Grant MINTER_ROLE + BURNER_ROLE on the token to the CCIP pool**.
9. **Permissionless CCIP self-serve registration**:
   `RegistryModuleOwnerCustom.registerAdminViaGetCCIPAdmin(token)`.
   Anyone can call this; the registry resolves the token's
   `getCCIPAdmin()` to determine the admin candidate.
10. **From CCIP_ADMIN**:
    `TokenAdminRegistry.acceptAdminRole(token)`.
11. **From CCIP_ADMIN**:
    `TokenAdminRegistry.setPool(token, POOL_ADDR)`.
12. **(Optional) PoR feed wire** if `POR_FEED` is set:
    `token.setPorFeed(POR_FEED)` from CCIP_ADMIN.

After step 11 the token is CCIP-registered and minting via the pool
will succeed. Step 12 gates further mints behind reserve sufficiency
+ feed freshness once a PoR feed is wired.

## Per-lane wiring (after deploy on both ends)

Per-lane rate limits and remote-pool registration must be applied to
**each pool on both sides** after both source and destination have
deployed. Auditors will see one `applyChainUpdates` transaction per
remote lane on each chain.

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

Per-chain CCIP `chainSelector` values are at
`docs.chain.link/ccip/directory`.

## Rate limit policy

Defaults — reviewed and locked at the May 2026 contract README baseline:

| Side | Capacity | Rate |
|---|---|---|
| Outbound | 1,000,000 RIVR | 100/sec |
| Inbound | 1,000,000 RIVR | 100/sec |

Bucket-based: `capacity` is the maximum single-tx size, `rate` is the
refill speed. At 100 RIVR/sec, a fully drained 1M bucket refills in
~10,000 seconds (~2.8 hours).

**Posture**: tight at launch; loosen only on observed legitimate
demand. The lesson from cross-chain incidents in 2025–2026 (KelpDAO,
Multichain, Nomad) is that unbounded drain windows turn even subtle
attestation flaws into catastrophic losses. Tightening further is
acceptable; loosening requires CCIP_ADMIN multisig timelock.

## Verify post-deploy

Cast calls that auditors should run against the broadcast addresses
to verify the deploy landed in the expected shape:

```bash
# 1. CCIP registry shows correct admin + pool
cast call $TOKEN_ADMIN_REGISTRY \
  "getTokenConfig(address)(address,address,address)" \
  $RIVR_TOKEN --rpc-url $RPC_URL
# Expected: (CCIP_ADMIN, 0x0, POOL_ADDR)

# 2. getCCIPAdmin matches the env-supplied CCIP_ADMIN
cast call $RIVR_TOKEN "getCCIPAdmin()(address)" --rpc-url $RPC_URL
# Expected: $CCIP_ADMIN

# 3. CCIP_ADMIN != DEFAULT_ADMIN (role split invariant)
cast call $RIVR_TOKEN "hasRole(bytes32,address)(bool)" \
  $(cast keccak "DEFAULT_ADMIN_ROLE") $CCIP_ADMIN --rpc-url $RPC_URL
# Expected: false

cast call $RIVR_TOKEN "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  $CCIP_ADMIN --rpc-url $RPC_URL
# Expected: false (DEFAULT_ADMIN_ROLE is bytes32(0) in OZ AccessControl)

# 4. Pool has MINTER + BURNER on the token
cast call $RIVR_TOKEN "hasRole(bytes32,address)(bool)" \
  $(cast keccak "MINTER_ROLE") $POOL_ADDR --rpc-url $RPC_URL
cast call $RIVR_TOKEN "hasRole(bytes32,address)(bool)" \
  $(cast keccak "BURNER_ROLE") $POOL_ADDR --rpc-url $RPC_URL
# Expected: true / true

# 5. Token has TOKEN_ROLE on each mutable registry
cast call $MANDATE_REGISTRY "hasRole(bytes32,address)(bool)" \
  $(cast keccak "TOKEN_ROLE") $RIVR_TOKEN --rpc-url $RPC_URL
cast call $STREAM_REGISTRY "hasRole(bytes32,address)(bool)" \
  $(cast keccak "TOKEN_ROLE") $RIVR_TOKEN --rpc-url $RPC_URL
# Expected: true / true

# 6. Policy hook has POLICY_HOOK_ROLE on stream registry
cast call $STREAM_REGISTRY "hasRole(bytes32,address)(bool)" \
  $(cast keccak "POLICY_HOOK_ROLE") $POLICY_HOOK --rpc-url $RPC_URL
# Expected: true

# 7. Registries wired into the token
cast call $RIVR_TOKEN "kyaRegistry()(address)" --rpc-url $RPC_URL
cast call $RIVR_TOKEN "mandateRegistry()(address)" --rpc-url $RPC_URL
cast call $RIVR_TOKEN "streamRegistry()(address)" --rpc-url $RPC_URL
cast call $RIVR_TOKEN "policyHook()(address)" --rpc-url $RPC_URL
# Expected: matches the addresses from steps 1-4 of the deploy sequence

# 8. PoR feed (mainnet only)
cast call $RIVR_TOKEN "porFeed()(address)" --rpc-url $RPC_URL
# Expected: $POR_FEED (or address(0) if not yet wired — flag for follow-up)
```

## Initial state expectations

Immediately post-deploy, before any user interaction:

| Property | Expected |
|---|---|
| `totalSupply()` | `0` |
| `balanceOf(any)` | `0` |
| `paused()` | `false` |
| `kyaRegistry().lastSyncedAt(any)` | `0` (KyaSyncWorker has not yet posted any VCs) |
| `mandateRegistry.recordOf(any).principal` | `address(0)` (no mandates lazily registered yet) |
| `streamRegistry.recordOf(any).payer` | `address(0)` (no streams opened) |
| `policyHook.kyaRegistry()` | matches step-1 deploy address |
| `policyHook.sanctionsOracle()` | matches the env-supplied `sanctionsOracle` arg (may be `address(0)`) |

**Mint posture at launch**: zero balance held by anyone. The first
mint goes through CCIP from a source chain (or directly from
`MINTER_ROLE` for treasury seeding). Any treasury seeding mint MUST
come from a multisig — not from the deployer EOA — and MUST be
covered by a PoR feed reading at least the seeded amount if `porFeed`
is wired. With `porFeed == address(0)` the PoR gate short-circuits;
auditors should flag this as a deploy-time warning to be resolved
before public issuance opens.

## Threat model at deploy

| Threat | Mitigation at deploy time |
|---|---|
| Compromised deployer EOA reuses CCIP_ADMIN slot | Constructor reverts on `CCIP_ADMIN == DEFAULT_ADMIN`; deployer EOA holds neither role post-deploy. |
| Pool wired before MINTER granted | Pool address is set in step 11 (`setPool`), MINTER granted in step 8. CCIP `releaseOrMint` would revert until step 8 completes; sequencing is enforced by the script. |
| Wrong `TOKEN_ADMIN_REGISTRY` per chain | Auditor verifies against `docs.chain.link/ccip/directory` before signing the broadcast. |
| Scaffold pool shipped to mainnet | Operator-side contract: PR review checks that `POOL_ADDR` resolves to a Chainlink-deployed pool, not the in-tree `RivierBurnMintTokenPool.sol` scaffold (which does not contain DON wiring). |
| Mainnet without PoR feed | Deploy emits warning event; ops follow-up wires `setPorFeed` before opening public issuance. PoR-gated mints fail-closed (revert on stale or insufficient feed). |
| Per-lane rate limits set too loose | Defaults (1M RIVR / 100 RIVR/sec) are conservative; loosening requires CCIP_ADMIN multisig timelock; auditors flag any `applyChainUpdates` raising the cap above 1M without timelock evidence. |

## Reproducibility for auditors

The 5 contracts in this directory plus the four launch-test files
covered in [src/rivier-token/README.md](./src/rivier-token/README.md) constitute the full
deploy artifact. To reproduce a deploy locally:

1. `forge build --skip "src/drop/**" --skip "src/loyalty/**" --skip "src/membership/**" --skip "src/randomness/**"`
2. `forge test --match-path "test/rivier-token/**" -vv` — should land 189/189.
3. Request `script/DeployRivierCCT.s.sol` under NDA via
   `security@rivier.ai` for the broadcast-bound script. The script
   itself contains no novel logic beyond the sequence above — it's a
   deterministic `vm.startBroadcast() → CREATE → role grants →
   register → setPool` driver that an auditor can reconstruct from
   the steps in this document.

## References

- Per-chain CCIP registry directory:
  https://docs.chain.link/ccip/directory
- Chainlink CCT documentation:
  https://docs.chain.link/ccip/concepts/cross-chain-tokens
- `TokenAdminRegistry` source:
  https://github.com/smartcontractkit/ccip/blob/main/contracts/src/v0.8/ccip/tokenAdminRegistry/TokenAdminRegistry.sol
- `BurnMintTokenPool` source:
  https://github.com/smartcontractkit/ccip/blob/main/contracts/src/v0.8/ccip/pools/BurnMintTokenPool.sol
- `RegistryModuleOwnerCustom` source:
  https://github.com/smartcontractkit/ccip/blob/main/contracts/src/v0.8/ccip/tokenAdminRegistry/RegistryModuleOwnerCustom.sol
