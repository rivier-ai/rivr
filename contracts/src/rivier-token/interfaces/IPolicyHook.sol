// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MandateEnvelope} from "../types/MandateEnvelope.sol";
import {IntentClass} from "../types/IntentClass.sol";
import {RefusalReason} from "../types/RefusalReason.sol";

/**
 * @title IPolicyHook
 * @notice Policy chain consulted by the RIVR token on every transfer
 *         path. Per design doc §4.
 *
 * Methods return `(RefusalReason, bytes32 ctx)` — they DO NOT revert.
 * The token contract decides whether to revert based on the returned
 * reason. This decoupling is what makes `dryRun` byte-equivalent to
 * the real path: the simulator runs the same hook methods through
 * `staticcall` and reads back the same (reason, ctx) tuple a real
 * tx would observe.
 *
 * `OK` means "no objection." Any other RefusalReason is the exact
 * code the token will revert with via `RivierRefused(reason, ctx)`.
 *
 * The hook itself sits behind a 7-day timelock — `POLICY_ADMIN_ROLE`
 * is the timelock contract, never an EOA. PolicyHook freezes
 * permanently once the launch milestone fires (audit clean +
 * $500M circulating OR 18 months mainnet operation); see CLAUDE.md
 * §"PolicyHook upgradability — freeze at milestone".
 */
interface IPolicyHook {
    /**
     * @notice Mandate-bound single-leg check. Called by
     *         `transferWithMandate` after KYA + cap checks pass.
     *
     *         Wires KYA + Chainalysis sanctions + Travel Rule
     *         attestation hash + (post-launch) jurisdiction /
     *         velocity / counterparty / RWA gates.
     *
     * @param caller       msg.sender on the token (typically the agent)
     * @param from         payer
     * @param to           payee
     * @param amount       wei amount of the asset
     * @param asset        token contract address (RIVR or other)
     * @param namespace    payer namespace; zero = DEFAULT_NS
     * @param intentClass  IntentClass tag
     * @param memoHash     producer-supplied 32-byte memo hash
     * @param mandate      the authorising MandateEnvelope (already
     *                     signature-verified by the token before this call)
     */
    function checkMandateBound(
        address caller,
        address from,
        address to,
        uint256 amount,
        address asset,
        bytes32 namespace,
        IntentClass intentClass,
        bytes32 memoHash,
        MandateEnvelope calldata mandate
    ) external view returns (RefusalReason reason, bytes32 ctx);

    /**
     * @notice Plain (non-mandate) transfer check. Called by the token's
     *         direct transfer paths only when those paths are policy-gated
     *         (sanctions screen). KYA is NOT consulted — plain transfers
     *         do not assume agent provenance.
     */
    function checkPlain(
        address caller,
        address from,
        address to,
        uint256 amount,
        address asset
    ) external view returns (RefusalReason reason, bytes32 ctx);

    /**
     * @notice Batch check. Called by `batchProgrammableTransfer` once
     *         per-leg policy decisions are needed. Returns the FIRST
     *         refusal across the batch (with the leg index packed into
     *         `ctx` so the caller can identify which leg failed).
     *
     *         Token enforces the cumulative cap once at the batch
     *         level against the sum of `amounts[]`; this hook is
     *         responsible for per-leg KYA / sanctions / Travel Rule
     *         decisions.
     */
    function checkBatch(
        address caller,
        address[] calldata from,
        address[] calldata to,
        uint256[] calldata amounts,
        address[] calldata assets,
        bytes32[] calldata namespaces,
        IntentClass[] calldata intentClasses,
        bytes32[] calldata memoHashes,
        MandateEnvelope calldata mandate
    ) external view returns (RefusalReason reason, bytes32 ctx);
}
