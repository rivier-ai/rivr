# RIVR

Reference implementation of an AI- and agent-native programmable stablecoin.

**Status**: pre-launch / testnet. Independent contributor project. Audit not yet commissioned.

## What this is

RIVR is a stablecoin where mandate validation, agent attestation, programmable batching, and continuous settlement streams are token-contract primitives — not orchestration above an inert ERC-20.

This repo contains:

- `contracts/src/rivier-token/` — EVM token contract suite (`RivierTokenCCT.sol` + registries + policy hook + types).
- `contracts/test/rivier-token/` — 113 forge tests covering the `dryRun` byte-equivalence invariant, namespace sum-preservation under fuzzing, replay protection, and reentrancy safety of cumulative-spend tracking.
- `docs/design/rivr.md` — design document (Executive Summary; the broader implementation doc is private to the operating team).

## Layout

```
contracts/
  src/rivier-token/
    RivierTokenCCT.sol           — token contract
    types/                       — MandateEnvelope, RefusalReason, IntentClass, ...
    interfaces/                  — IBurnMintERC20, IGetCCIPAdmin, IPoRFeed, ...
    registries/                  — RivierKyaRegistry, RivierMandateRegistry, RivierStreamRegistry
    policy/                      — RivierPolicyHook, IPolicyHook
  test/rivier-token/             — 113 forge tests
  foundry.toml
docs/
  design/rivr.md                 — design summary
LICENSE                          — MIT
```

## Running the tests

```
cd contracts
forge test --match-path "test/rivier-token/**" \
  --skip "src/drop/**" --skip "src/loyalty/**" \
  --skip "src/membership/**" --skip "src/randomness/**" -vv
```

The `--skip` flags exclude unrelated sibling contracts that are not part of the RIVR token surface and have their own dependency requirements.

## Contributions and standards work

The RIVR design is being submitted to standards venues. Live submissions:

- x402 Foundation: discussion at [x402-foundation/x402#2176](https://github.com/x402-foundation/x402/issues/2176), draft spec PR at [x402-foundation/x402#2175](https://github.com/x402-foundation/x402/pull/2175).
- AP2 / FIDO Alliance: sample/SDK alignment discussion at [google-agentic-commerce/AP2#255](https://github.com/google-agentic-commerce/AP2/issues/255).

The same constraint envelope is rail-agnostic; submissions to fiat-rail venues (Visa TAP, Mastercard agent-pay, ISO 20022 agentic-payment work, IETF, W3C, FIDO/WebAuthn) are sequenced after the on-chain spec lands.

## License

MIT — see [LICENSE](LICENSE).
