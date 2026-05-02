// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MandateEnvelope} from "./MandateEnvelope.sol";
import {IntentClass} from "./IntentClass.sol";

/**
 * @title StreamParams
 * @notice Parameters for opening a continuous-settlement stream (per-second-of-compute,
 *         per-token-of-inference, recurring micropayments collapsed into a stream).
 *
 * Streams are mandate-aware: every stream carries its authorizing MandateEnvelope so
 * the StreamRegistry can auto-pause when the mandate's KYA goes stale, the cumulative
 * cap is hit, or sanctions/velocity flags fire.
 *
 * Fields:
 *   - recipient: the address receiving the stream
 *   - ratePerSecond: tokens/sec, 18-dec like the underlying ERC-20
 *   - startsAt: unix seconds. Withdrawals before this time return 0.
 *   - endsAt: unix seconds. Stream auto-closes at this time. Set to type(uint64).max
 *             for open-ended streams (still bounded by mandate.expiresAt).
 *   - namespaceFromPayer: ERC-6909 namespace the payer's stream debits from. Zero
 *             namespace (DEFAULT_NS) means the payer's main RIVR balance.
 *   - mandate: the authorizing envelope. Stream re-checks the mandate on every
 *             withdrawFromStream — if the mandate has been revoked or its caps
 *             exhausted, the stream auto-pauses.
 *   - intentClass: typically STREAM_OPEN at construction, recorded for analytics.
 *             Withdrawals emit STREAM_WITHDRAW regardless.
 */
struct StreamParams {
    address recipient;
    uint256 ratePerSecond;
    uint64 startsAt;
    uint64 endsAt;
    bytes32 namespaceFromPayer;
    MandateEnvelope mandate;
    IntentClass intentClass;
}
