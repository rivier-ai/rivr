// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RivierTestBase} from "./Base.t.sol";
import {RivierMandateRegistry} from "../../src/rivier-token/registries/RivierMandateRegistry.sol";
import {IRivierMandateRegistry} from "../../src/rivier-token/interfaces/IRivierMandateRegistry.sol";

/// @notice Unit tests for RivierMandateRegistry — lazy registration,
/// cumulative spend tracking, immutability of binding image,
/// principal-only revoke, recovery-role mass revoke.
///
/// Most paths are TOKEN_ROLE-gated; tests impersonate via
/// `vm.prank(address(token))` since that's the only TOKEN_ROLE holder.
contract RivierMandateRegistryTest is RivierTestBase {
    bytes32 internal constant MID = keccak256("mandate-1");
    bytes32 internal constant KYA = keccak256("kya-1");

    function _record(uint256 amountUsd) internal {
        vm.prank(address(token));
        mandates.recordMandateUse(
            MID,
            PRINCIPAL,
            AGENT,
            KYA,
            10_000 * 1e6,                     // maxTotalUsd
            uint64(block.timestamp + 30 days),
            amountUsd
        );
    }

    // ─── lazy registration + cumulative ─────────────────────────────

    function test_recordMandateUse_lazyRegisters_andTracksSpend() public {
        _record(100 * 1e6);
        IRivierMandateRegistry.MandateRecord memory rec = mandates.recordOf(MID);
        assertEq(rec.principal, PRINCIPAL);
        assertEq(rec.agent, AGENT);
        assertEq(rec.kyaCredentialHash, KYA);
        assertEq(rec.maxTotalUsd, 10_000 * 1e6);
        assertEq(rec.cumulativeSpentUsd, 100 * 1e6);
        assertFalse(rec.revoked);
        assertEq(mandates.cumulativeSpend(MID), 100 * 1e6);
    }

    function test_recordMandateUse_secondUse_accumulates() public {
        _record(100 * 1e6);
        _record(250 * 1e6);
        assertEq(mandates.cumulativeSpend(MID), 350 * 1e6);
    }

    function test_recordMandateUse_overCap_reverts() public {
        _record(9_000 * 1e6);
        vm.prank(address(token));
        vm.expectRevert(
            abi.encodeWithSelector(
                RivierMandateRegistry.CumulativeCapExceeded.selector,
                MID,
                10_001 * 1e6,
                10_000 * 1e6
            )
        );
        mandates.recordMandateUse(
            MID,
            PRINCIPAL,
            AGENT,
            KYA,
            10_000 * 1e6,
            uint64(block.timestamp + 30 days),
            1_001 * 1e6
        );
    }

    function test_recordMandateUse_immutableFieldChanged_reverts() public {
        _record(100 * 1e6);
        vm.prank(address(token));
        vm.expectRevert(
            abi.encodeWithSelector(
                RivierMandateRegistry.ImmutableFieldChanged.selector,
                MID
            )
        );
        // Change agent — must revert.
        mandates.recordMandateUse(
            MID,
            PRINCIPAL,
            address(0xBEEF),
            KYA,
            10_000 * 1e6,
            uint64(block.timestamp + 30 days),
            10 * 1e6
        );
    }

    function test_recordMandateUse_byNonTokenRole_reverts() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        mandates.recordMandateUse(
            MID, PRINCIPAL, AGENT, KYA, 10_000 * 1e6,
            uint64(block.timestamp + 30 days), 1 * 1e6
        );
    }

    // ─── revokeMandate ──────────────────────────────────────────────

    function test_revokeMandate_principalSucceeds_blocksFurtherUse() public {
        _record(100 * 1e6);
        vm.prank(PRINCIPAL);
        mandates.revokeMandate(MID);
        assertTrue(mandates.recordOf(MID).revoked);

        vm.prank(address(token));
        vm.expectRevert(
            abi.encodeWithSelector(RivierMandateRegistry.MandateAlreadyRevoked.selector, MID)
        );
        mandates.recordMandateUse(
            MID, PRINCIPAL, AGENT, KYA, 10_000 * 1e6,
            uint64(block.timestamp + 30 days), 1 * 1e6
        );
    }

    function test_revokeMandate_byNonPrincipal_reverts() public {
        _record(100 * 1e6);
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        mandates.revokeMandate(MID);
    }

    function test_revokeMandate_unknown_reverts() public {
        vm.prank(PRINCIPAL);
        vm.expectRevert(
            abi.encodeWithSelector(RivierMandateRegistry.UnknownMandate.selector, MID)
        );
        mandates.revokeMandate(MID);
    }

    // ─── revokeAllMandates ──────────────────────────────────────────

    function test_revokeAllMandates_recoveryFlipsAll() public {
        bytes32 m1 = keccak256("m1");
        bytes32 m2 = keccak256("m2");
        // Register two mandates for the same principal.
        vm.startPrank(address(token));
        mandates.recordMandateUse(
            m1, PRINCIPAL, AGENT, KYA, 1_000 * 1e6,
            uint64(block.timestamp + 30 days), 1 * 1e6
        );
        mandates.recordMandateUse(
            m2, PRINCIPAL, AGENT, KYA, 1_000 * 1e6,
            uint64(block.timestamp + 30 days), 1 * 1e6
        );
        vm.stopPrank();

        vm.prank(RECOVERY);
        mandates.revokeAllMandates(PRINCIPAL);
        assertTrue(mandates.recordOf(m1).revoked);
        assertTrue(mandates.recordOf(m2).revoked);
    }

    function test_revokeAllMandates_byNonRecovery_reverts() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        mandates.revokeAllMandates(PRINCIPAL);
    }

    // ─── views ──────────────────────────────────────────────────────

    function test_isRevokedOrExpired_unknown_returnsFalse() public view {
        // Unknown mandates are first-use — NOT revoked. The token validates
        // the envelope signature and expiry directly; this view only flags
        // explicit revoke or post-registration expiry.
        assertFalse(mandates.isRevokedOrExpired(keccak256("never-seen")));
    }

    function test_projectCumulative_returnsExpected() public {
        _record(100 * 1e6);
        (uint256 projected, uint256 cap, bool exceed) =
            mandates.projectCumulative(MID, 250 * 1e6);
        assertEq(projected, 350 * 1e6);
        assertEq(cap, 10_000 * 1e6);
        assertFalse(exceed);
    }

    function test_projectCumulative_overCap_flagsExceed() public {
        _record(9_900 * 1e6);
        (, , bool exceed) = mandates.projectCumulative(MID, 200 * 1e6);
        assertTrue(exceed);
    }
}
