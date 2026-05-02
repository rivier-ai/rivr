// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title RefusalReason
 * @notice Typed refusal codes returned by the policy chain on every transferring path.
 *
 * Every contract that participates in a transfer decision (token, registries, policy hook,
 * dry-run simulator) returns these codes — never strings, never opaque error data — so
 * agents and off-chain systems can branch on the cause without parsing revert messages.
 *
 * `OK` is the success sentinel (value 0). Any non-zero value is a refusal.
 *
 * The `RivierRefused` error is emitted by the token contract whenever a policy chain
 * returns a non-OK reason. The `ctx` field is a 32-byte tag the producing contract
 * fills with whatever pinpoints the rejection (mandate id, stream ref, kya credential
 * hash, etc.). Off-chain consumers MUST treat `ctx` as opaque and dispatch on `reason`.
 */
enum RefusalReason {
    OK,                           // 0  — the only success value
    KYA_INVALID,                  // 1
    KYA_EXPIRED,                  // 2
    KYA_REVOKED,                  // 3
    MANDATE_EXPIRED,              // 4
    MANDATE_PER_TX_CAP,           // 5
    MANDATE_CUMULATIVE_CAP,       // 6
    MANDATE_ASSET_NOT_ALLOWED,    // 7
    MANDATE_PRINCIPAL_MISMATCH,   // 8
    MANDATE_REVOKED,              // 9
    MANDATE_SIGNATURE_INVALID,    // 10
    MANDATE_AGENT_SIGNATURE_INVALID, // 11
    JURISDICTION_GATE,            // 12
    TRAVEL_RULE_BLOCK,            // 13
    SANCTIONS_HIT,                // 14
    POR_STALE,                    // 15
    POR_INSUFFICIENT,             // 16
    PERMISSIONED_RWA,             // 17
    PAUSED,                       // 18
    NAMESPACE_INSUFFICIENT,       // 19
    STREAM_INVALID,               // 20
    STREAM_PAUSED,                // 21
    POLICY_HOOK_REVERTED,         // 22 — reserved; PolicyHook should never revert
    UNKNOWN                       // 23 — defensive; should never be returned
}

/**
 * @notice Standard refusal error. Every transferring path that consults the policy chain
 *         and gets a non-OK reason MUST revert with this exact error.
 * @param reason The typed code (see RefusalReason enum)
 * @param ctx    32-byte tag pinpointing the rejection (mandate id, stream ref, etc.).
 *               Format is reason-dependent and documented per producer. Treat as opaque
 *               unless you know the producer.
 */
error RivierRefused(RefusalReason reason, bytes32 ctx);
