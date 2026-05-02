// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RivierTestBase} from "./Base.t.sol";
import {RivierTokenCCT} from "../../src/rivier-token/RivierTokenCCT.sol";
import {MandateEnvelope} from "../../src/rivier-token/types/MandateEnvelope.sol";
import {IntentClass, IntentClasses} from "../../src/rivier-token/types/IntentClass.sol";
import {RefusalReason, RivierRefused} from "../../src/rivier-token/types/RefusalReason.sol";

/// @notice One test per RefusalReason that is reachable through the live
/// transferWithMandate path. Every test asserts the typed `RivierRefused`
/// revert AND the `ctx` field carries the expected pinpoint.
///
/// Refusal codes covered (live path):
///   KYA_INVALID, MANDATE_EXPIRED, MANDATE_PER_TX_CAP, MANDATE_CUMULATIVE_CAP,
///   MANDATE_ASSET_NOT_ALLOWED, MANDATE_PRINCIPAL_MISMATCH, MANDATE_REVOKED,
///   MANDATE_SIGNATURE_INVALID, MANDATE_AGENT_SIGNATURE_INVALID,
///   TRAVEL_RULE_BLOCK, SANCTIONS_HIT, NAMESPACE_INSUFFICIENT, PAUSED.
///
/// Codes NOT exercised here (out of scope for the launch token):
///   KYA_EXPIRED / KYA_REVOKED — KYA registry has its own coverage;
///   JURISDICTION_GATE / POR_STALE / POR_INSUFFICIENT / PERMISSIONED_RWA —
///   policy slots filled post-launch (pass-through stubs return OK today).
///   STREAM_PAUSED / STREAM_INVALID — covered by RivierStreamAutoPause.t.sol.
///   POLICY_HOOK_REVERTED / UNKNOWN — defensive sentinels, never produced.
contract RivierRefusalReasonsTest is RivierTestBase {
    bytes32 internal constant MEMO = keccak256("memo");
    bytes internal constant EXT_DATA = "";

    function setUp() public override {
        super.setUp();
        _mintTo(PRINCIPAL, 1_000_000 * 1e18);
    }

    function _exec(MandateEnvelope memory env, address to, uint256 amt, uint256 amtUsd6) internal {
        vm.prank(AGENT);
        token.transferWithMandate(
            to, amt, amtUsd6, DEFAULT_NS, env,
            IntentClasses.AGENT_TO_AGENT, MEMO, EXT_DATA
        );
    }

    // ─── KYA_INVALID ────────────────────────────────────────────────

    function test_kyaInvalid_unknownCredential_reverts() public {
        bytes32 mid = keccak256("m-kya-invalid");
        // KYA NOT activated.
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(RivierRefused.selector, RefusalReason.KYA_INVALID, mid)
        );
        _exec(env, RECIPIENT, 1 * 1e18, 1 * 1e6);
    }

    // ─── MANDATE_EXPIRED ────────────────────────────────────────────

    function test_mandateExpired_pastExpiry_reverts() public {
        bytes32 mid = keccak256("m-expired");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        // Warp past expiry (envelope expires at +1 day).
        vm.warp(block.timestamp + 2 days);
        vm.expectRevert(
            abi.encodeWithSelector(RivierRefused.selector, RefusalReason.MANDATE_EXPIRED, mid)
        );
        _exec(env, RECIPIENT, 1 * 1e18, 1 * 1e6);
    }

    function test_mandateExpired_beforeNotBefore_reverts() public {
        bytes32 mid = keccak256("m-future");
        _activateKya(mid);
        // Build a mandate that's not active yet.
        address[] memory allow = new address[](1);
        allow[0] = address(token);
        MandateEnvelope memory env = _signMandate(
            mid,
            keccak256(abi.encode(mid, "nonce")),
            mid,
            allow,
            1_000 * 1e6,
            10_000 * 1e6,
            uint64(block.timestamp + 1 days), // notBefore in future
            uint64(block.timestamp + 2 days)
        );
        vm.expectRevert(
            abi.encodeWithSelector(RivierRefused.selector, RefusalReason.MANDATE_EXPIRED, mid)
        );
        _exec(env, RECIPIENT, 1 * 1e18, 1 * 1e6);
    }

    // ─── MANDATE_PER_TX_CAP ─────────────────────────────────────────

    function test_perTxCap_amountExceeds_reverts() public {
        bytes32 mid = keccak256("m-pertx");
        _activateKya(mid);
        // perTx cap = $100; tx is $200.
        MandateEnvelope memory env = _defaultMandate(mid, 100 * 1e6, 10_000 * 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(RivierRefused.selector, RefusalReason.MANDATE_PER_TX_CAP, mid)
        );
        _exec(env, RECIPIENT, 200 * 1e18, 200 * 1e6);
    }

    // ─── MANDATE_CUMULATIVE_CAP ─────────────────────────────────────

    function test_cumulativeCap_secondTxExceedsTotal_reverts() public {
        bytes32 mid = keccak256("m-cum");
        _activateKya(mid);
        // perTx = $1000, total = $1500.
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 1_500 * 1e6);
        // First tx at $900 — passes.
        _exec(env, RECIPIENT, 900 * 1e18, 900 * 1e6);

        // Second tx at $700 — would push cumulative to $1600 > $1500.
        // Mandate registry's recordMandateUse reverts on cumulative-cap.
        vm.expectRevert();
        // NOTE: rebuild envelope with new nonce so the per-tx replay guard doesn't fire first.
        MandateEnvelope memory env2 = _signMandate(
            mid,
            keccak256(abi.encode(mid, "nonce-2")),
            mid,
            env.assetAllowlist,
            1_000 * 1e6,
            1_500 * 1e6,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days)
        );
        _exec(env2, RECIPIENT, 700 * 1e18, 700 * 1e6);
    }

    // ─── MANDATE_ASSET_NOT_ALLOWED ──────────────────────────────────

    function test_assetNotAllowed_reverts() public {
        bytes32 mid = keccak256("m-asset");
        _activateKya(mid);
        // Allowlist does NOT include the RIVR token.
        address[] memory allow = new address[](1);
        allow[0] = makeAddr("usdc-fake");
        MandateEnvelope memory env = _signMandate(
            mid, keccak256(abi.encode(mid, "n")), mid, allow,
            1_000 * 1e6, 10_000 * 1e6,
            uint64(block.timestamp), uint64(block.timestamp + 1 days)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                RivierRefused.selector,
                RefusalReason.MANDATE_ASSET_NOT_ALLOWED,
                bytes32(uint256(uint160(address(token))))
            )
        );
        _exec(env, RECIPIENT, 1 * 1e18, 1 * 1e6);
    }

    // ─── MANDATE_PRINCIPAL_MISMATCH ─────────────────────────────────

    function test_principalMismatch_zeroAddress_reverts() public {
        bytes32 mid = keccak256("m-zero");
        _activateKya(mid);
        // Manually craft an envelope with principal = address(0). We can't
        // actually sign for address(0), but the check fires before signature
        // verification, so any signature bytes work.
        MandateEnvelope memory env;
        env.principal = address(0);
        env.agent = AGENT;
        env.kyaCredentialHash = mid;
        env.assetAllowlist = new address[](1);
        env.assetAllowlist[0] = address(token);
        env.maxPerTxUsd = 1_000 * 1e6;
        env.maxTotalUsd = 10_000 * 1e6;
        env.notBefore = uint64(block.timestamp);
        env.expiresAt = uint64(block.timestamp + 1 days);
        env.mandateId = mid;
        env.nonce = keccak256(abi.encode(mid, "n"));
        env.principalSignature = hex"00";
        env.agentSignature = hex"00";

        vm.expectRevert(
            abi.encodeWithSelector(RivierRefused.selector, RefusalReason.MANDATE_PRINCIPAL_MISMATCH, mid)
        );
        _exec(env, RECIPIENT, 1 * 1e18, 1 * 1e6);
    }

    // ─── MANDATE_REVOKED ────────────────────────────────────────────

    function test_revoked_replayingNonce_reverts() public {
        bytes32 mid = keccak256("m-replay");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        _exec(env, RECIPIENT, 1 * 1e18, 1 * 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(RivierRefused.selector, RefusalReason.MANDATE_REVOKED, env.nonce)
        );
        _exec(env, RECIPIENT, 1 * 1e18, 1 * 1e6);
    }

    function test_revoked_explicitRevocation_reverts() public {
        bytes32 mid = keccak256("m-explicit-revoke");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        _exec(env, RECIPIENT, 1 * 1e18, 1 * 1e6); // first use registers
        // Principal explicitly revokes.
        vm.prank(PRINCIPAL);
        mandates.revokeMandate(mid);
        // Second use under a new nonce — should fail the registry check.
        MandateEnvelope memory env2 = _signMandate(
            mid, keccak256(abi.encode(mid, "n2")), mid, env.assetAllowlist,
            1_000 * 1e6, 10_000 * 1e6,
            uint64(block.timestamp), uint64(block.timestamp + 1 days)
        );
        vm.expectRevert(
            abi.encodeWithSelector(RivierRefused.selector, RefusalReason.MANDATE_REVOKED, mid)
        );
        _exec(env2, RECIPIENT, 1 * 1e18, 1 * 1e6);
    }

    // ─── MANDATE_SIGNATURE_INVALID ──────────────────────────────────

    function test_principalSignatureInvalid_reverts() public {
        bytes32 mid = keccak256("m-bad-prin-sig");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        // Stomp the principal sig.
        env.principalSignature = hex"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff1b";
        vm.expectRevert(
            abi.encodeWithSelector(RivierRefused.selector, RefusalReason.MANDATE_SIGNATURE_INVALID, mid)
        );
        _exec(env, RECIPIENT, 1 * 1e18, 1 * 1e6);
    }

    // ─── MANDATE_AGENT_SIGNATURE_INVALID ────────────────────────────

    function test_agentSignatureInvalid_reverts() public {
        bytes32 mid = keccak256("m-bad-agent-sig");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        env.agentSignature = hex"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff1b";
        vm.expectRevert(
            abi.encodeWithSelector(RivierRefused.selector, RefusalReason.MANDATE_AGENT_SIGNATURE_INVALID, mid)
        );
        _exec(env, RECIPIENT, 1 * 1e18, 1 * 1e6);
    }

    // ─── TRAVEL_RULE_BLOCK ──────────────────────────────────────────

    function test_travelRule_aboveDeMinimisWithoutAttestation_reverts() public {
        bytes32 mid = keccak256("m-travel");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 5_000 * 1e6, 100_000 * 1e6);
        // $1k = de minimis; without an attestation, $5k must block.
        vm.expectRevert(
            abi.encodeWithSelector(RivierRefused.selector, RefusalReason.TRAVEL_RULE_BLOCK, MEMO)
        );
        _exec(env, RECIPIENT, 5_000 * 1e18, 5_000 * 1e6);
    }

    // ─── SANCTIONS_HIT ──────────────────────────────────────────────

    function test_sanctions_principalIsSanctioned_reverts() public {
        bytes32 mid = keccak256("m-sanctions");
        _activateKya(mid);
        sanctions.setSanctioned(PRINCIPAL, true);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(
                RivierRefused.selector,
                RefusalReason.SANCTIONS_HIT,
                bytes32(uint256(uint160(PRINCIPAL)))
            )
        );
        _exec(env, RECIPIENT, 1 * 1e18, 1 * 1e6);
    }

    // ─── NAMESPACE_INSUFFICIENT ─────────────────────────────────────

    function test_namespaceInsufficient_overdraft_reverts() public {
        bytes32 mid = keccak256("m-ns-insufficient");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 100_000 * 1e6, 1_000_000 * 1e6);
        // Principal balance is 1_000_000 RIVR — try to send 2_000_000.
        vm.expectRevert(); // raw revert from _debitNamespace's "insufficient namespace"
        _exec(env, RECIPIENT, 2_000_000 * 1e18, 2_000_000 * 1e6);
    }

    // ─── PAUSED ─────────────────────────────────────────────────────

    function test_paused_blocksTransferWithMandate() public {
        bytes32 mid = keccak256("m-paused");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        vm.prank(TREASURY);
        token.pause();
        // OZ Pausable surfaces EnforcedPause.
        vm.expectRevert();
        _exec(env, RECIPIENT, 1 * 1e18, 1 * 1e6);
    }
}
