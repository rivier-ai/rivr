// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RivierTestBase} from "./Base.t.sol";
import {RivierPolicyHook} from "../../src/rivier-token/policy/RivierPolicyHook.sol";
import {MandateEnvelope} from "../../src/rivier-token/types/MandateEnvelope.sol";
import {IntentClass, IntentClasses} from "../../src/rivier-token/types/IntentClass.sol";
import {RefusalReason} from "../../src/rivier-token/types/RefusalReason.sol";

/// @notice Unit tests for RivierPolicyHook — KYA + sanctions + travel rule
/// integration; pass-through stubs return OK; timelock guard on setters.
contract RivierPolicyHookTest is RivierTestBase {
    bytes32 internal constant KYA = keccak256("kya-policy");
    bytes32 internal constant MEMO = keccak256("memo");

    function setUp() public override {
        super.setUp();
        _activateKya(KYA);
    }

    /// @dev Tiny stub envelope just so we can hand the hook a calldata
    ///      MandateEnvelope. Only `kyaCredentialHash` is read by the hook.
    function _stub() internal pure returns (MandateEnvelope memory env) {
        env.kyaCredentialHash = KYA;
        env.assetAllowlist = new address[](0);
    }

    // ─── checkMandateBound ──────────────────────────────────────────

    function test_checkMandateBound_okPath_returnsOK() public {
        MandateEnvelope memory env = _stub();
        (RefusalReason r, ) = hook.checkMandateBound(
            address(this), PRINCIPAL, RECIPIENT, 1 * 1e6, address(token),
            DEFAULT_NS, IntentClasses.AGENT_TO_AGENT, MEMO, env
        );
        assertEq(uint8(r), uint8(RefusalReason.OK));
    }

    function test_checkMandateBound_kyaInvalid_returnsKYA_INVALID() public {
        // Different (un-activated) credential hash.
        MandateEnvelope memory env = _stub();
        env.kyaCredentialHash = keccak256("never-synced");
        (RefusalReason r, ) = hook.checkMandateBound(
            address(this), PRINCIPAL, RECIPIENT, 1 * 1e6, address(token),
            DEFAULT_NS, IntentClasses.AGENT_TO_AGENT, MEMO, env
        );
        assertEq(uint8(r), uint8(RefusalReason.KYA_INVALID));
    }

    function test_checkMandateBound_sanctionedFrom_returnsSANCTIONS_HIT() public {
        sanctions.setSanctioned(PRINCIPAL, true);
        MandateEnvelope memory env = _stub();
        (RefusalReason r, bytes32 ctx) = hook.checkMandateBound(
            address(this), PRINCIPAL, RECIPIENT, 1 * 1e6, address(token),
            DEFAULT_NS, IntentClasses.AGENT_TO_AGENT, MEMO, env
        );
        assertEq(uint8(r), uint8(RefusalReason.SANCTIONS_HIT));
        assertEq(ctx, bytes32(uint256(uint160(PRINCIPAL))));
    }

    function test_checkMandateBound_aboveDeMinimisWithoutAttestation_blocks() public {
        MandateEnvelope memory env = _stub();
        // Just at the de minimis ($1k = 1e9 amountUsd6) — no attestation.
        (RefusalReason r, ) = hook.checkMandateBound(
            address(this), PRINCIPAL, RECIPIENT, 1_000 * 1e6, address(token),
            DEFAULT_NS, IntentClasses.AGENT_TO_AGENT, MEMO, env
        );
        assertEq(uint8(r), uint8(RefusalReason.TRAVEL_RULE_BLOCK));
    }

    function test_checkMandateBound_aboveDeMinimisWithAttestation_passes() public {
        _attestTravelRule(MEMO);
        MandateEnvelope memory env = _stub();
        (RefusalReason r, ) = hook.checkMandateBound(
            address(this), PRINCIPAL, RECIPIENT, 1_000 * 1e6, address(token),
            DEFAULT_NS, IntentClasses.AGENT_TO_AGENT, MEMO, env
        );
        assertEq(uint8(r), uint8(RefusalReason.OK));
    }

    function test_checkMandateBound_belowDeMinimis_skipsTravelRule() public {
        MandateEnvelope memory env = _stub();
        // $999 — below the $1k threshold, no attestation needed.
        (RefusalReason r, ) = hook.checkMandateBound(
            address(this), PRINCIPAL, RECIPIENT, 999 * 1e6, address(token),
            DEFAULT_NS, IntentClasses.AGENT_TO_AGENT, MEMO, env
        );
        assertEq(uint8(r), uint8(RefusalReason.OK));
    }

    // ─── checkPlain ─────────────────────────────────────────────────

    function test_checkPlain_returnsOKWithoutKya() public {
        // Plain transfers do NOT consult KYA.
        (RefusalReason r, ) = hook.checkPlain(
            address(this), makeAddr("alice"), makeAddr("bob"), 1 * 1e6, address(token)
        );
        assertEq(uint8(r), uint8(RefusalReason.OK));
    }

    function test_checkPlain_sanctionedFrom_blocks() public {
        address bad = makeAddr("bad");
        sanctions.setSanctioned(bad, true);
        (RefusalReason r, ) = hook.checkPlain(
            address(this), bad, makeAddr("ok"), 1 * 1e6, address(token)
        );
        assertEq(uint8(r), uint8(RefusalReason.SANCTIONS_HIT));
    }

    // ─── markTravelRuleAttested role gate ───────────────────────────

    function test_markTravelRuleAttested_byNonAttestor_reverts() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        hook.markTravelRuleAttested(MEMO);
    }

    // ─── setSanctionsOracle role gate ───────────────────────────────

    function test_setSanctionsOracle_byPolicyAdmin_succeeds() public {
        vm.prank(POLICY_ADMIN);
        hook.setSanctionsOracle(address(0));
        assertEq(address(hook.sanctionsOracle()), address(0));
    }

    function test_setSanctionsOracle_byNonAdmin_reverts() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        hook.setSanctionsOracle(address(0));
    }
}
