// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RivierTestBase} from "./Base.t.sol";
import {IRivierKyaRegistry} from "../../src/rivier-token/interfaces/IRivierKyaRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

/// @notice Unit tests for RivierKyaRegistry — sync-wallet permissioning,
/// staleness threshold, revocation propagation, expiry semantics.
contract RivierKyaRegistryTest is RivierTestBase {
    bytes32 internal constant CRED = keccak256("cred-1");
    address internal ISSUER;

    function setUp() public override {
        super.setUp();
        ISSUER = makeAddr("vc-issuer");
    }

    // ─── upsertCredential ───────────────────────────────────────────

    function test_upsertCredential_byKyaSyncRole_persists() public {
        uint64 exp = uint64(block.timestamp + 30 days);
        vm.prank(KYA_SYNC);
        kya.upsertCredential(CRED, ISSUER, exp);

        IRivierKyaRegistry.KyaRecord memory rec = kya.recordOf(CRED);
        assertEq(rec.issuer, ISSUER, "issuer");
        assertEq(uint8(rec.status), uint8(IRivierKyaRegistry.KyaStatus.ACTIVE), "status");
        assertEq(rec.expiresAt, exp, "expiresAt");
        assertEq(rec.lastSyncedAt, uint64(block.timestamp), "syncedAt");
        assertTrue(kya.isValid(CRED));
    }

    function test_upsertCredential_byNonRole_reverts() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        kya.upsertCredential(CRED, ISSUER, uint64(block.timestamp + 1 days));
    }

    function test_upsertCredential_alreadyExpired_reverts() public {
        // expiresAt must be > block.timestamp
        vm.warp(1000);
        vm.prank(KYA_SYNC);
        vm.expectRevert(bytes("RIVR-KYA: already expired"));
        kya.upsertCredential(CRED, ISSUER, uint64(500));
    }

    // ─── revokeCredential ────────────────────────────────────────────

    function test_revokeCredential_flipsStatusAndInvalidates() public {
        vm.prank(KYA_SYNC);
        kya.upsertCredential(CRED, ISSUER, uint64(block.timestamp + 30 days));
        assertTrue(kya.isValid(CRED));

        vm.prank(KYA_SYNC);
        kya.revokeCredential(CRED);

        IRivierKyaRegistry.KyaRecord memory rec = kya.recordOf(CRED);
        assertEq(uint8(rec.status), uint8(IRivierKyaRegistry.KyaStatus.REVOKED));
        assertFalse(kya.isValid(CRED));
    }

    function test_revokeCredential_unknown_reverts() public {
        vm.prank(KYA_SYNC);
        vm.expectRevert(
            abi.encodeWithSelector(bytes4(keccak256("UnknownCredential(bytes32)")), CRED)
        );
        kya.revokeCredential(CRED);
    }

    // ─── lazy expiry ────────────────────────────────────────────────

    function test_isValid_returnsFalseAfterExpiry_withoutRevoke() public {
        uint64 exp = uint64(block.timestamp + 1 days);
        vm.prank(KYA_SYNC);
        kya.upsertCredential(CRED, ISSUER, exp);
        assertTrue(kya.isValid(CRED));

        vm.warp(exp + 1);
        assertFalse(kya.isValid(CRED), "expired by lazy timestamp");
        // record's stored status is still ACTIVE — registry doesn't auto-flip.
        IRivierKyaRegistry.KyaRecord memory rec = kya.recordOf(CRED);
        assertEq(uint8(rec.status), uint8(IRivierKyaRegistry.KyaStatus.ACTIVE));
    }

    // ─── staleness ──────────────────────────────────────────────────

    function test_staleness_unknownIsMax() public view {
        assertEq(kya.staleness(CRED), type(uint64).max);
    }

    function test_staleness_advancesWithBlockTimestamp() public {
        vm.prank(KYA_SYNC);
        kya.upsertCredential(CRED, ISSUER, uint64(block.timestamp + 30 days));
        assertEq(kya.staleness(CRED), 0);

        vm.warp(block.timestamp + 90);
        assertEq(kya.staleness(CRED), 90);
    }
}
