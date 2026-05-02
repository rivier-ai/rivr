// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RivierTestBase} from "./Base.t.sol";
import {RivierStreamRegistry} from "../../src/rivier-token/registries/RivierStreamRegistry.sol";
import {IRivierStreamRegistry} from "../../src/rivier-token/interfaces/IRivierStreamRegistry.sol";
import {StreamParams} from "../../src/rivier-token/types/StreamParams.sol";
import {MandateEnvelope} from "../../src/rivier-token/types/MandateEnvelope.sol";
import {IntentClass, IntentClasses} from "../../src/rivier-token/types/IntentClass.sol";
import {RefusalReason} from "../../src/rivier-token/types/RefusalReason.sol";

/// @notice Unit tests for RivierStreamRegistry — accrual math, role
/// gating, auto-pause via PolicyHook callback, payer-only resume,
/// and the window-shift-on-resume invariant (recipient is NOT credited
/// for paused time).
///
/// Most paths are TOKEN_ROLE-gated; tests impersonate via
/// `vm.prank(address(token))` since that's the only TOKEN_ROLE holder.
/// Pause is POLICY_HOOK_ROLE-gated; tests impersonate via
/// `vm.prank(address(hook))` since the hook is the only POLICY_HOOK_ROLE
/// holder (see Base.t.sol setUp).
contract RivierStreamAutoPauseTest is RivierTestBase {
    bytes32 internal constant MID = keccak256("stream-mandate");

    /// @dev Build a minimal stream-params struct. The registry only reads
    ///      `recipient`, `ratePerSecond`, `startsAt`, `endsAt`,
    ///      `namespaceFromPayer`, `intentClass`, and `mandate.principal` /
    ///      `mandate.mandateId` — signatures are never re-verified here
    ///      (the token does that before calling openStream).
    function _params(
        uint256 ratePerSec,
        uint64 startsAt,
        uint64 endsAt
    ) internal view returns (StreamParams memory p) {
        MandateEnvelope memory env;
        env.principal = PRINCIPAL;
        env.agent = AGENT;
        env.mandateId = MID;
        env.assetAllowlist = new address[](0);

        p.recipient = RECIPIENT;
        p.ratePerSecond = ratePerSec;
        p.startsAt = startsAt;
        p.endsAt = endsAt;
        p.namespaceFromPayer = DEFAULT_NS;
        p.mandate = env;
        p.intentClass = IntentClasses.STREAM_OPEN;
    }

    function _open(uint256 ratePerSec) internal returns (bytes32 streamRef) {
        StreamParams memory p = _params(
            ratePerSec,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 hours)
        );
        vm.prank(address(token));
        streamRef = streams.openStream(p);
    }

    // ─── openStream ─────────────────────────────────────────────────

    function test_openStream_persists_andEmitsEvent() public {
        StreamParams memory p = _params(
            1e15, // 0.001 RIVR/sec
            uint64(block.timestamp),
            uint64(block.timestamp + 1 hours)
        );
        vm.prank(address(token));
        bytes32 streamRef = streams.openStream(p);

        IRivierStreamRegistry.Stream memory s = streams.recordOf(streamRef);
        assertEq(s.payer, PRINCIPAL);
        assertEq(s.recipient, RECIPIENT);
        assertEq(s.ratePerSecond, 1e15);
        assertEq(s.startedAt, uint64(block.timestamp));
        assertEq(s.endsAt, uint64(block.timestamp + 1 hours));
        assertFalse(s.paused);
    }

    function test_openStream_zeroRate_reverts() public {
        StreamParams memory p = _params(
            0,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 hours)
        );
        vm.prank(address(token));
        vm.expectRevert(
            abi.encodeWithSelector(RivierStreamRegistry.InvalidRate.selector, uint256(0))
        );
        streams.openStream(p);
    }

    function test_openStream_invertedWindow_reverts() public {
        uint64 startsAt = uint64(block.timestamp + 1 hours);
        uint64 endsAt = uint64(block.timestamp);
        StreamParams memory p = _params(1e15, startsAt, endsAt);
        vm.prank(address(token));
        vm.expectRevert(
            abi.encodeWithSelector(
                RivierStreamRegistry.InvalidStreamWindow.selector,
                startsAt,
                endsAt
            )
        );
        streams.openStream(p);
    }

    function test_openStream_duplicate_reverts() public {
        StreamParams memory p = _params(
            1e15,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 hours)
        );
        vm.startPrank(address(token));
        bytes32 streamRef = streams.openStream(p);
        vm.expectRevert(
            abi.encodeWithSelector(
                RivierStreamRegistry.StreamAlreadyExists.selector,
                streamRef
            )
        );
        streams.openStream(p);
        vm.stopPrank();
    }

    function test_openStream_byNonTokenRole_reverts() public {
        StreamParams memory p = _params(
            1e15,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 hours)
        );
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        streams.openStream(p);
    }

    // ─── accrual ────────────────────────────────────────────────────

    function test_accrual_linearOverElapsed() public {
        bytes32 streamRef = _open(1e15); // 0.001 RIVR/sec
        // Immediately after open: zero elapsed, zero accrued.
        assertEq(streams.streamBalance(streamRef), 0);

        vm.warp(block.timestamp + 100);
        assertEq(streams.streamBalance(streamRef), 100 * 1e15);
    }

    function test_accrual_capsAtEndsAt() public {
        bytes32 streamRef = _open(1e15);
        // Warp past endsAt — accrual caps at the window length (1h).
        vm.warp(block.timestamp + 2 hours);
        assertEq(streams.streamBalance(streamRef), 3600 * 1e15);
    }

    function test_streamBalance_unknown_returnsZero() public view {
        assertEq(streams.streamBalance(keccak256("never-opened")), 0);
    }

    // ─── withdrawFromStream ─────────────────────────────────────────

    function test_withdraw_decrementsAccrued() public {
        bytes32 streamRef = _open(1e15);
        vm.warp(block.timestamp + 100);
        // 100 * 1e15 accrued
        vm.prank(address(token));
        streams.withdrawFromStream(streamRef, 50 * 1e15);
        assertEq(streams.streamBalance(streamRef), 50 * 1e15);
        assertEq(streams.recordOf(streamRef).withdrawn, 50 * 1e15);
    }

    function test_withdraw_overAccrued_reverts() public {
        bytes32 streamRef = _open(1e15);
        vm.warp(block.timestamp + 10);
        // 10 * 1e15 accrued; ask for 11 * 1e15.
        vm.prank(address(token));
        vm.expectRevert(
            abi.encodeWithSelector(
                RivierStreamRegistry.InsufficientAccrued.selector,
                streamRef,
                11 * 1e15,
                10 * 1e15
            )
        );
        streams.withdrawFromStream(streamRef, 11 * 1e15);
    }

    function test_withdraw_byNonTokenRole_reverts() public {
        bytes32 streamRef = _open(1e15);
        vm.warp(block.timestamp + 100);
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        streams.withdrawFromStream(streamRef, 1 * 1e15);
    }

    function test_withdraw_whilePaused_reverts() public {
        bytes32 streamRef = _open(1e15);
        vm.warp(block.timestamp + 100);
        vm.prank(address(hook));
        streams.pauseStream(streamRef, RefusalReason.SANCTIONS_HIT);

        vm.prank(address(token));
        vm.expectRevert(
            abi.encodeWithSelector(
                RivierStreamRegistry.StreamPausedError.selector,
                streamRef
            )
        );
        streams.withdrawFromStream(streamRef, 1 * 1e15);
    }

    // ─── pauseStream (auto-pause via PolicyHook) ────────────────────

    function test_pause_byPolicyHookRole_succeeds() public {
        bytes32 streamRef = _open(1e15);
        vm.prank(address(hook));
        streams.pauseStream(streamRef, RefusalReason.MANDATE_CUMULATIVE_CAP);

        IRivierStreamRegistry.Stream memory s = streams.recordOf(streamRef);
        assertTrue(s.paused);
        assertEq(uint8(s.pauseReason), uint8(RefusalReason.MANDATE_CUMULATIVE_CAP));
        assertEq(s.pausedAt, uint64(block.timestamp));
    }

    function test_pause_isIdempotent() public {
        bytes32 streamRef = _open(1e15);
        vm.startPrank(address(hook));
        streams.pauseStream(streamRef, RefusalReason.SANCTIONS_HIT);

        // Second pause is a no-op (different reason ignored).
        uint64 firstPauseAt = streams.recordOf(streamRef).pausedAt;
        vm.warp(block.timestamp + 30);
        streams.pauseStream(streamRef, RefusalReason.KYA_REVOKED);
        vm.stopPrank();

        IRivierStreamRegistry.Stream memory s = streams.recordOf(streamRef);
        assertEq(s.pausedAt, firstPauseAt, "pausedAt should not advance on re-pause");
        // First reason wins.
        assertEq(uint8(s.pauseReason), uint8(RefusalReason.SANCTIONS_HIT));
    }

    function test_pause_byNonHookRole_reverts() public {
        bytes32 streamRef = _open(1e15);
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        streams.pauseStream(streamRef, RefusalReason.SANCTIONS_HIT);
    }

    function test_pause_freezesAccrual() public {
        bytes32 streamRef = _open(1e15);
        vm.warp(block.timestamp + 100); // 100 * 1e15 accrued
        vm.prank(address(hook));
        streams.pauseStream(streamRef, RefusalReason.SANCTIONS_HIT);

        // Accrual frozen at pause time — warp another 200s, balance unchanged.
        vm.warp(block.timestamp + 200);
        assertEq(streams.streamBalance(streamRef), 100 * 1e15);
    }

    // ─── resumeStream ───────────────────────────────────────────────

    function test_resume_byPayer_shiftsEndsAtForward() public {
        bytes32 streamRef = _open(1e15);
        uint64 originalEndsAt = streams.recordOf(streamRef).endsAt;

        vm.warp(block.timestamp + 100);
        vm.prank(address(hook));
        streams.pauseStream(streamRef, RefusalReason.SANCTIONS_HIT);

        // 60s of paused time.
        vm.warp(block.timestamp + 60);
        vm.prank(PRINCIPAL);
        streams.resumeStream(streamRef);

        IRivierStreamRegistry.Stream memory s = streams.recordOf(streamRef);
        assertFalse(s.paused);
        assertEq(s.endsAt, originalEndsAt + 60, "endsAt extended by paused duration");
        assertEq(uint8(s.pauseReason), uint8(RefusalReason.OK));
    }

    function test_resume_byNonPayer_reverts() public {
        bytes32 streamRef = _open(1e15);
        vm.prank(address(hook));
        streams.pauseStream(streamRef, RefusalReason.SANCTIONS_HIT);

        vm.prank(RECIPIENT); // even recipient cannot resume
        vm.expectRevert(
            abi.encodeWithSelector(
                RivierStreamRegistry.NotPayer.selector,
                streamRef,
                RECIPIENT,
                PRINCIPAL
            )
        );
        streams.resumeStream(streamRef);
    }

    function test_resume_whenNotPaused_reverts() public {
        bytes32 streamRef = _open(1e15);
        vm.prank(PRINCIPAL);
        vm.expectRevert(
            abi.encodeWithSelector(
                RivierStreamRegistry.StreamNotPaused.selector,
                streamRef
            )
        );
        streams.resumeStream(streamRef);
    }

    function test_resume_pauseDurationCompensatedByTailShift() public {
        // Contract semantic: paused time DOES count toward elapsed once
        // resumed (the accrual function reads min(now, endsAt) - startedAt
        // with no paused-duration subtraction), but the recipient is
        // compensated by an equal-duration extension of `endsAt`. So the
        // total amount the stream pays out remains
        // `ratePerSecond * (endsAt - startedAt)` of the original window.
        bytes32 streamRef = _open(1e15);
        uint64 originalEndsAt = streams.recordOf(streamRef).endsAt;

        vm.warp(block.timestamp + 100); // 100 * 1e15 accrued
        vm.prank(address(hook));
        streams.pauseStream(streamRef, RefusalReason.SANCTIONS_HIT);

        // 60s paused — accrual frozen at pause time.
        vm.warp(block.timestamp + 60);
        assertEq(streams.streamBalance(streamRef), 100 * 1e15);

        vm.prank(PRINCIPAL);
        streams.resumeStream(streamRef);

        // Tail extended by exactly the paused duration.
        IRivierStreamRegistry.Stream memory s = streams.recordOf(streamRef);
        assertEq(s.endsAt, originalEndsAt + 60);

        // After resume, the elapsed-since-startedAt naturally includes
        // the paused window — but the extended tail compensates one-for-one.
        vm.warp(block.timestamp + 50);
        // 100s pre-pause + 60s paused + 50s post-resume = 210s elapsed
        // since startedAt — but the new endsAt is now `originalEndsAt + 60`,
        // which is still well in the future, so balance = 210 * 1e15.
        assertEq(streams.streamBalance(streamRef), 210 * 1e15);
    }

    // ─── closeStream ────────────────────────────────────────────────

    function test_close_byPayer_truncatesWindow() public {
        bytes32 streamRef = _open(1e15);
        vm.warp(block.timestamp + 100);
        vm.prank(PRINCIPAL);
        streams.closeStream(streamRef);

        // endsAt clamped to now; further warp doesn't add accrual.
        vm.warp(block.timestamp + 1000);
        assertEq(streams.streamBalance(streamRef), 100 * 1e15);
    }

    function test_close_byRecipient_truncatesWindow() public {
        bytes32 streamRef = _open(1e15);
        vm.warp(block.timestamp + 100);
        vm.prank(RECIPIENT);
        streams.closeStream(streamRef);

        vm.warp(block.timestamp + 1000);
        assertEq(streams.streamBalance(streamRef), 100 * 1e15);
    }

    function test_close_byThirdParty_reverts() public {
        bytes32 streamRef = _open(1e15);
        address rando = makeAddr("rando");
        vm.prank(rando);
        vm.expectRevert(
            abi.encodeWithSelector(
                RivierStreamRegistry.NotPayerOrRecipient.selector,
                streamRef,
                rando
            )
        );
        streams.closeStream(streamRef);
    }

    function test_close_unknown_reverts() public {
        bytes32 streamRef = keccak256("never-opened");
        vm.prank(PRINCIPAL);
        vm.expectRevert(
            abi.encodeWithSelector(
                RivierStreamRegistry.UnknownStream.selector,
                streamRef
            )
        );
        streams.closeStream(streamRef);
    }
}
