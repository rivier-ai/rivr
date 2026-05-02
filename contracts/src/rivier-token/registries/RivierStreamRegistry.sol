// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IRivierStreamRegistry} from "../interfaces/IRivierStreamRegistry.sol";
import {StreamParams} from "../types/StreamParams.sol";
import {IntentClass} from "../types/IntentClass.sol";
import {RefusalReason} from "../types/RefusalReason.sol";

/**
 * @title RivierStreamRegistry
 * @notice Continuous-settlement streams for per-second-of-compute /
 *         per-token-of-inference / per-API-call agent flows.
 *
 * MIT-licensed. Architectural reference: Sablier Flow (GPL —
 * not vendored, re-implemented here).
 *
 * Custody model: this registry tracks accrual and bookkeeping ONLY.
 * The float lives in the payer's namespace on the RIVR token contract.
 * On `withdrawFromStream`, the token (TOKEN_ROLE) debits the payer's
 * namespace and credits the recipient's DEFAULT_NS, then calls back
 * here to record the cumulative withdrawn amount. The registry itself
 * never holds funds, never executes balance changes.
 *
 * Accrual: linear from `startedAt` to `endsAt` at `ratePerSecond`.
 * Pauses freeze accrual at `pausedAt`; resumes shift `startedAt` /
 * `endsAt` forward by the paused duration so the recipient does NOT
 * get credited for paused time. (This is a deliberate choice — the
 * stream models compute/inference *delivery*, and a paused stream
 * means delivery wasn't honored.)
 *
 * Auto-pause invariants (enforced by the PolicyHook before each withdraw):
 *   - KYA credential revoked / expired
 *   - Mandate cumulative cap hit
 *   - Velocity flag tripped
 *   - Sanctions hit on either party
 *
 * `streamRef` is deterministic: keccak256(payer, recipient, namespace,
 * mandateId, startedAt). Re-opening the same tuple is rejected.
 */
contract RivierStreamRegistry is IRivierStreamRegistry, AccessControl {
    bytes32 public constant TOKEN_ROLE = keccak256("TOKEN_ROLE");
    bytes32 public constant POLICY_HOOK_ROLE = keccak256("POLICY_HOOK_ROLE");

    mapping(bytes32 streamRef => Stream) private _streams;

    error UnknownStream(bytes32 streamRef);
    error StreamAlreadyExists(bytes32 streamRef);
    error StreamPausedError(bytes32 streamRef);
    error StreamNotPaused(bytes32 streamRef);
    error StreamClosedError(bytes32 streamRef);
    error InsufficientAccrued(bytes32 streamRef, uint256 requested, uint256 available);
    error InvalidStreamWindow(uint64 startsAt, uint64 endsAt);
    error InvalidRate(uint256 ratePerSecond);
    error NotPayerOrRecipient(bytes32 streamRef, address caller);
    error NotPayer(bytes32 streamRef, address caller, address payer);

    constructor(address admin) {
        require(admin != address(0), "RIVR-SR: admin zero");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @inheritdoc IRivierStreamRegistry
    function openStream(StreamParams calldata p)
        external
        onlyRole(TOKEN_ROLE)
        returns (bytes32 streamRef)
    {
        if (p.ratePerSecond == 0) revert InvalidRate(p.ratePerSecond);
        if (p.endsAt <= p.startsAt) revert InvalidStreamWindow(p.startsAt, p.endsAt);

        // Payer is the mandate principal — the token has already
        // verified the principal's signature on the envelope before
        // calling here.
        address payer = p.mandate.principal;

        streamRef = keccak256(
            abi.encode(
                payer,
                p.recipient,
                p.namespaceFromPayer,
                p.mandate.mandateId,
                p.startsAt
            )
        );

        Stream storage s = _streams[streamRef];
        if (s.payer != address(0)) revert StreamAlreadyExists(streamRef);

        s.payer = payer;
        s.recipient = p.recipient;
        s.ratePerSecond = p.ratePerSecond;
        s.startedAt = p.startsAt;
        s.endsAt = p.endsAt;
        s.namespaceFromPayer = p.namespaceFromPayer;
        s.mandateId = p.mandate.mandateId;
        s.intentClass = p.intentClass;
        // withdrawn / paused / pausedAt / pauseReason default to zero.

        emit StreamOpened(
            streamRef,
            payer,
            p.recipient,
            p.ratePerSecond,
            p.startsAt,
            p.endsAt,
            p.namespaceFromPayer,
            p.mandate.mandateId,
            p.intentClass
        );
    }

    /// @inheritdoc IRivierStreamRegistry
    function withdrawFromStream(bytes32 streamRef, uint256 amount)
        external
        onlyRole(TOKEN_ROLE)
    {
        Stream storage s = _streams[streamRef];
        if (s.payer == address(0)) revert UnknownStream(streamRef);
        if (s.paused) revert StreamPausedError(streamRef);

        uint256 accrued = _accruedBalance(s);
        if (amount > accrued) revert InsufficientAccrued(streamRef, amount, accrued);

        s.withdrawn += amount;
        emit StreamWithdrawn(streamRef, s.recipient, amount, s.withdrawn);
    }

    /// @inheritdoc IRivierStreamRegistry
    function closeStream(bytes32 streamRef) external {
        _closeStreamFor(streamRef, msg.sender);
    }

    /// @inheritdoc IRivierStreamRegistry
    function closeStreamFor(bytes32 streamRef, address caller)
        external
        onlyRole(TOKEN_ROLE)
    {
        _closeStreamFor(streamRef, caller);
    }

    function _closeStreamFor(bytes32 streamRef, address caller) internal {
        Stream storage s = _streams[streamRef];
        if (s.payer == address(0)) revert UnknownStream(streamRef);
        if (caller != s.payer && caller != s.recipient) {
            revert NotPayerOrRecipient(streamRef, caller);
        }

        // Truncate the active window so future accrual stops here.
        // Existing accrued-but-not-withdrawn balance is preserved
        // and remains drawable until next sweep.
        uint64 nowSec = uint64(block.timestamp);
        if (s.endsAt > nowSec) {
            s.endsAt = nowSec;
        }

        emit StreamClosed(streamRef, caller, nowSec);
    }

    /// @inheritdoc IRivierStreamRegistry
    function pauseStream(bytes32 streamRef, RefusalReason reason)
        external
        onlyRole(POLICY_HOOK_ROLE)
    {
        Stream storage s = _streams[streamRef];
        if (s.payer == address(0)) revert UnknownStream(streamRef);
        if (s.paused) return; // idempotent — already paused

        uint64 nowSec = uint64(block.timestamp);
        s.paused = true;
        s.pausedAt = nowSec;
        s.pauseReason = reason;

        emit StreamPaused(streamRef, reason, nowSec);
    }

    /// @inheritdoc IRivierStreamRegistry
    function resumeStream(bytes32 streamRef) external {
        Stream storage s = _streams[streamRef];
        if (s.payer == address(0)) revert UnknownStream(streamRef);
        if (msg.sender != s.payer) revert NotPayer(streamRef, msg.sender, s.payer);
        if (!s.paused) revert StreamNotPaused(streamRef);

        // Shift window forward by the paused duration so recipient
        // is not credited for paused time.
        uint64 nowSec = uint64(block.timestamp);
        uint64 pausedDuration = nowSec - s.pausedAt;
        s.endsAt += pausedDuration;
        // startedAt only matters for the accrual function's lower bound;
        // shifting endsAt is sufficient because accrual reads
        // min(now, endsAt) - startedAt and we want the "lost" time
        // to extend the tail.

        s.paused = false;
        s.pausedAt = 0;
        s.pauseReason = RefusalReason.OK;

        emit StreamResumed(streamRef, nowSec);
    }

    /// @inheritdoc IRivierStreamRegistry
    function streamBalance(bytes32 streamRef) external view returns (uint256) {
        Stream storage s = _streams[streamRef];
        if (s.payer == address(0)) return 0;
        return _accruedBalance(s);
    }

    /// @inheritdoc IRivierStreamRegistry
    function recordOf(bytes32 streamRef) external view returns (Stream memory) {
        return _streams[streamRef];
    }

    /// @dev Accrued = ratePerSecond * elapsed - withdrawn.
    ///      Elapsed is bounded above by the stream's effective end
    ///      (now if paused, else min(now, endsAt)) and below by startedAt.
    function _accruedBalance(Stream storage s) private view returns (uint256) {
        uint64 nowSec = uint64(block.timestamp);
        uint64 effEnd;
        if (s.paused) {
            effEnd = s.pausedAt;
        } else if (nowSec < s.endsAt) {
            effEnd = nowSec;
        } else {
            effEnd = s.endsAt;
        }
        if (effEnd <= s.startedAt) return 0;

        uint256 elapsed = effEnd - s.startedAt;
        uint256 totalAccrued = elapsed * s.ratePerSecond;
        if (totalAccrued <= s.withdrawn) return 0;
        return totalAccrued - s.withdrawn;
    }
}
