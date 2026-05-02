// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {StreamParams} from "../types/StreamParams.sol";
import {MandateEnvelope} from "../types/MandateEnvelope.sol";
import {IntentClass} from "../types/IntentClass.sol";
import {RefusalReason} from "../types/RefusalReason.sol";

/**
 * @title IRivierStreamRegistry
 * @notice Continuous-settlement streams (per-second-of-compute /
 *         per-token-of-inference). MIT re-implementation; architectural
 *         reference: Sablier Flow (GPL — not vendored).
 *
 * A stream is a mandate-bounded promise to pay `ratePerSecond` from
 * `payer`'s `namespaceFromPayer` to `recipient` across the open window
 * [startedAt, endsAt). Withdrawals draw against the accrued balance and
 * decrement the underlying namespace at withdraw time (the namespace
 * holds the float; the stream record tracks accrual + withdrawn).
 *
 * Auto-pause invariants (enforced by the PolicyHook callback before
 * each withdraw):
 *   - KYA credential revoked / expired
 *   - Mandate cumulative cap hit
 *   - Velocity flag tripped
 *   - Sanctions hit on either party
 *
 * `pauseStream` is the PolicyHook's exit valve — it records the
 * RefusalReason that produced the pause so the recipient can surface
 * it to their UI without re-running the policy chain.
 */
interface IRivierStreamRegistry {
    /// @dev Emitted when a stream is opened.
    event StreamOpened(
        bytes32 indexed streamRef,
        address indexed payer,
        address indexed recipient,
        uint256 ratePerSecond,
        uint64 startsAt,
        uint64 endsAt,
        bytes32 namespaceFromPayer,
        bytes32 mandateId,
        IntentClass intentClass
    );

    /// @dev Emitted on each successful withdraw against the stream.
    event StreamWithdrawn(
        bytes32 indexed streamRef,
        address indexed recipient,
        uint256 amount,
        uint256 cumulativeWithdrawn
    );

    /// @dev Emitted when the stream is closed (by payer, recipient, or expiry sweep).
    event StreamClosed(bytes32 indexed streamRef, address indexed by, uint64 at);

    /// @dev Emitted when the PolicyHook auto-pauses the stream.
    event StreamPaused(bytes32 indexed streamRef, RefusalReason reason, uint64 at);

    /// @dev Emitted when a paused stream is resumed (by payer after the
    ///      blocking condition clears).
    event StreamResumed(bytes32 indexed streamRef, uint64 at);

    struct Stream {
        address payer;
        address recipient;
        uint256 ratePerSecond;
        uint64 startedAt;
        uint64 endsAt;
        uint256 withdrawn;
        bytes32 namespaceFromPayer;
        bytes32 mandateId;
        IntentClass intentClass;
        bool paused;
        uint64 pausedAt;
        RefusalReason pauseReason;
    }

    /**
     * @notice Open a stream. ROLE-gated to TOKEN_ROLE (the RIVR token contract).
     *         Returns a deterministic `streamRef` derived from
     *         (payer, recipient, namespace, mandateId, startedAt).
     */
    function openStream(StreamParams calldata p) external returns (bytes32 streamRef);

    /**
     * @notice Pull `amount` accrued from the stream into `recipient`.
     *         ROLE-gated to TOKEN_ROLE. Reverts if `amount` exceeds
     *         currently-accrued balance, if the stream is paused, or
     *         if the policy chain refuses.
     */
    function withdrawFromStream(bytes32 streamRef, uint256 amount) external;

    /**
     * @notice Close the stream. Callable by payer or recipient.
     *         Future accrual stops; any outstanding accrued balance
     *         remains withdrawable until the next sweep.
     */
    function closeStream(bytes32 streamRef) external;

    /**
     * @notice TOKEN_ROLE entry point: close the stream on behalf of
     *         `caller`. Same payer-or-recipient gate but msg.sender
     *         is the token forwarding the original caller. Used when
     *         users invoke closeStream via the RIVR token entry point.
     */
    function closeStreamFor(bytes32 streamRef, address caller) external;

    /**
     * @notice PolicyHook callback. Records the RefusalReason that
     *         tripped the pause. ROLE-gated to POLICY_HOOK_ROLE.
     */
    function pauseStream(bytes32 streamRef, RefusalReason reason) external;

    /**
     * @notice Payer-only resume after a paused stream's blocking
     *         condition clears (e.g. mandate refreshed, sanctions
     *         status corrected).
     */
    function resumeStream(bytes32 streamRef) external;

    /// @notice Currently-accrued, not-yet-withdrawn balance for the stream.
    function streamBalance(bytes32 streamRef) external view returns (uint256);

    /// @notice Full stream record. Zero-valued if unknown.
    function recordOf(bytes32 streamRef) external view returns (Stream memory);
}
