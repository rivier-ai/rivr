// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IntentClass
 * @notice Ontology of agent intents per design doc §3 IntentClass.
 *
 * Every transferring path takes an `IntentClass` so off-chain systems (analytics,
 * compliance, indexers, agent introspection) can dispatch on the kind of payment
 * without parsing memo blobs or guessing from amount shape.
 *
 * The values are stable. New classes append at the next free slot — never reuse,
 * never reorder. Wire-format consumers (event parsers) are expected to refuse
 * unknown values cleanly via the event's extensionVersion gate, not by guessing.
 */
type IntentClass is uint8;

library IntentClasses {
    // ── Direct payments ─────────────────────────────────────────────────────
    IntentClass internal constant UNSPECIFIED            = IntentClass.wrap(0x00);
    IntentClass internal constant P2P_TRANSFER           = IntentClass.wrap(0x01);
    IntentClass internal constant AGENT_TO_AGENT         = IntentClass.wrap(0x02);
    IntentClass internal constant AGENT_TO_HUMAN         = IntentClass.wrap(0x03);
    IntentClass internal constant HUMAN_TO_AGENT         = IntentClass.wrap(0x04);

    // ── Programmable & batched ──────────────────────────────────────────────
    IntentClass internal constant PROGRAMMABLE_BATCH     = IntentClass.wrap(0x05);
    IntentClass internal constant DVP_LEG                = IntentClass.wrap(0x06);
    IntentClass internal constant SETTLEMENT_LEG         = IntentClass.wrap(0x07);

    // ── Streams ─────────────────────────────────────────────────────────────
    IntentClass internal constant STREAM_OPEN            = IntentClass.wrap(0x08);
    IntentClass internal constant STREAM_WITHDRAW        = IntentClass.wrap(0x09);
    IntentClass internal constant STREAM_CLOSE           = IntentClass.wrap(0x0a);
    IntentClass internal constant STREAM_PAUSE           = IntentClass.wrap(0x0b);

    // ── Compute / inference micropayments ───────────────────────────────────
    IntentClass internal constant COMPUTE_PER_SECOND     = IntentClass.wrap(0x0c);
    IntentClass internal constant INFERENCE_PER_TOKEN    = IntentClass.wrap(0x0d);
    IntentClass internal constant API_CALL_X402          = IntentClass.wrap(0x0e);

    // ── Commerce / merchant ─────────────────────────────────────────────────
    IntentClass internal constant CHECKOUT_PURCHASE      = IntentClass.wrap(0x0f);
    IntentClass internal constant SUBSCRIPTION_CHARGE    = IntentClass.wrap(0x10);
    IntentClass internal constant LOYALTY_REWARD         = IntentClass.wrap(0x11);

    // ── Treasury / institutional ────────────────────────────────────────────
    IntentClass internal constant RESERVE_MINT           = IntentClass.wrap(0x12);
    IntentClass internal constant RESERVE_REDEEM         = IntentClass.wrap(0x13);
    IntentClass internal constant NAMESPACE_MOVE         = IntentClass.wrap(0x14);
    IntentClass internal constant CROSS_CHAIN_BURN_MINT  = IntentClass.wrap(0x15);

    function unwrap(IntentClass c) internal pure returns (uint8) {
        return IntentClass.unwrap(c);
    }

    function eq(IntentClass a, IntentClass b) internal pure returns (bool) {
        return IntentClass.unwrap(a) == IntentClass.unwrap(b);
    }
}
