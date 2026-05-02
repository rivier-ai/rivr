// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RivierTestBase} from "./Base.t.sol";
import {RivierPolicyHook} from "../../src/rivier-token/policy/RivierPolicyHook.sol";
import {MandateEnvelope} from "../../src/rivier-token/types/MandateEnvelope.sol";
import {IntentClass, IntentClasses} from "../../src/rivier-token/types/IntentClass.sol";
import {RefusalReason} from "../../src/rivier-token/types/RefusalReason.sol";

/// @notice Direct branch coverage for `RivierPolicyHook` — constructor zero
///         guards, `setKyaRegistry` happy/zero, `setSanctionsOracle` event,
///         `markTravelRuleAttested` happy path, `checkPlain`'s null-oracle
///         and sanctioned-to branches, `checkBatch` (entirely uncovered by
///         the base suite), and the de-minimis attestation paths.
contract RivierPolicyHookBranchCoverageTest is RivierTestBase {
    bytes32 internal constant KYA = keccak256("kya-policy-bcov");
    bytes32 internal constant MEMO = keccak256("memo-bcov");

    function setUp() public override {
        super.setUp();
        _activateKya(KYA);
    }

    function _stub() internal pure returns (MandateEnvelope memory env) {
        env.kyaCredentialHash = KYA;
        env.assetAllowlist = new address[](0);
    }

    // ─── constructor zero-address guards ──────────────────────────────

    function test_constructor_revertsOnZeroAdmin() public {
        vm.expectRevert(bytes("RIVR-PH: admin zero"));
        new RivierPolicyHook(address(0), POLICY_ADMIN, address(kya), address(sanctions));
    }

    function test_constructor_revertsOnZeroPolicyAdmin() public {
        vm.expectRevert(bytes("RIVR-PH: policy admin zero"));
        new RivierPolicyHook(TREASURY, address(0), address(kya), address(sanctions));
    }

    function test_constructor_revertsOnZeroKya() public {
        vm.expectRevert(bytes("RIVR-PH: kya zero"));
        new RivierPolicyHook(TREASURY, POLICY_ADMIN, address(0), address(sanctions));
    }

    function test_constructor_acceptsZeroSanctionsOracle() public {
        // sanctionsOracle MAY be address(0) on chains without Chainalysis.
        RivierPolicyHook fresh =
            new RivierPolicyHook(TREASURY, POLICY_ADMIN, address(kya), address(0));
        assertEq(address(fresh.sanctionsOracle()), address(0));
        assertEq(address(fresh.kyaRegistry()), address(kya));
    }

    // ─── setKyaRegistry ────────────────────────────────────────────────

    function test_setKyaRegistry_zeroReverts() public {
        vm.prank(POLICY_ADMIN);
        vm.expectRevert(bytes("RIVR-PH: kya zero"));
        hook.setKyaRegistry(address(0));
    }

    function test_setKyaRegistry_byPolicyAdmin_succeeds() public {
        address newReg = makeAddr("new-kya");
        vm.prank(POLICY_ADMIN);
        hook.setKyaRegistry(newReg);
        assertEq(address(hook.kyaRegistry()), newReg);
    }

    function test_setKyaRegistry_byNonAdmin_reverts() public {
        vm.prank(makeAddr("rando"));
        vm.expectRevert();
        hook.setKyaRegistry(makeAddr("new-kya"));
    }

    // ─── markTravelRuleAttested happy path ────────────────────────────

    function test_markTravelRuleAttested_byAttestor_succeeds() public {
        bytes32 hash = keccak256("attestation-1");
        vm.prank(ATTESTOR);
        hook.markTravelRuleAttested(hash);
        assertTrue(hook.travelRuleAttested(hash));
    }

    // ─── checkMandateBound: sanctioned `to` ────────────────────────────

    function test_checkMandateBound_sanctionedTo_returnsSANCTIONS_HIT() public {
        sanctions.setSanctioned(RECIPIENT, true);
        MandateEnvelope memory env = _stub();
        (RefusalReason r, bytes32 ctx) = hook.checkMandateBound(
            address(this), PRINCIPAL, RECIPIENT, 1 * 1e6, address(token),
            DEFAULT_NS, IntentClasses.AGENT_TO_AGENT, MEMO, env
        );
        assertEq(uint8(r), uint8(RefusalReason.SANCTIONS_HIT));
        assertEq(ctx, bytes32(uint256(uint160(RECIPIENT))));
    }

    function test_checkMandateBound_aboveDeMinimisZeroMemoHash_blocks() public {
        // amount above de-minimis but memoHash = 0 — must block on the
        // `memoHash == 0` short-circuit, not on the registry lookup.
        MandateEnvelope memory env = _stub();
        (RefusalReason r, ) = hook.checkMandateBound(
            address(this), PRINCIPAL, RECIPIENT, 1_000 * 1e6, address(token),
            DEFAULT_NS, IntentClasses.AGENT_TO_AGENT, bytes32(0), env
        );
        assertEq(uint8(r), uint8(RefusalReason.TRAVEL_RULE_BLOCK));
    }

    // ─── checkPlain: null sanctions oracle ─────────────────────────────

    function test_checkPlain_nullOracle_returnsOK() public {
        // Set sanctionsOracle to address(0) → the `if (oracle != 0)` block is skipped.
        vm.prank(POLICY_ADMIN);
        hook.setSanctionsOracle(address(0));

        (RefusalReason r, ) = hook.checkPlain(
            address(this), makeAddr("a"), makeAddr("b"), 1 * 1e6, address(token)
        );
        assertEq(uint8(r), uint8(RefusalReason.OK));
    }

    function test_checkPlain_sanctionedTo_blocks() public {
        address bad = makeAddr("bad-recipient");
        sanctions.setSanctioned(bad, true);
        (RefusalReason r, bytes32 ctx) = hook.checkPlain(
            address(this), makeAddr("ok"), bad, 1 * 1e6, address(token)
        );
        assertEq(uint8(r), uint8(RefusalReason.SANCTIONS_HIT));
        assertEq(ctx, bytes32(uint256(uint160(bad))));
    }

    // ─── checkMandateBound: null sanctions oracle ──────────────────────

    function test_checkMandateBound_nullOracle_skipsSanctionsCheck() public {
        vm.prank(POLICY_ADMIN);
        hook.setSanctionsOracle(address(0));

        MandateEnvelope memory env = _stub();
        (RefusalReason r, ) = hook.checkMandateBound(
            address(this), PRINCIPAL, RECIPIENT, 1 * 1e6, address(token),
            DEFAULT_NS, IntentClasses.AGENT_TO_AGENT, MEMO, env
        );
        assertEq(uint8(r), uint8(RefusalReason.OK));
    }

    // ─── checkBatch ────────────────────────────────────────────────────

    function test_checkBatch_okPath_returnsOK() public {
        address[] memory froms = new address[](2);
        address[] memory tos = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        address[] memory assets = new address[](2);
        bytes32[] memory namespaces = new bytes32[](2);
        IntentClass[] memory intentClasses = new IntentClass[](2);
        bytes32[] memory memoHashes = new bytes32[](2);

        froms[0] = PRINCIPAL; froms[1] = PRINCIPAL;
        tos[0] = RECIPIENT;   tos[1] = RECIPIENT;
        amounts[0] = 1 * 1e6; amounts[1] = 2 * 1e6;
        assets[0] = address(token); assets[1] = address(token);
        intentClasses[0] = IntentClasses.AGENT_TO_AGENT;
        intentClasses[1] = IntentClasses.AGENT_TO_AGENT;
        memoHashes[0] = MEMO; memoHashes[1] = MEMO;

        MandateEnvelope memory env = _stub();
        (RefusalReason r, ) = hook.checkBatch(
            address(this), froms, tos, amounts, assets, namespaces,
            intentClasses, memoHashes, env
        );
        assertEq(uint8(r), uint8(RefusalReason.OK));
    }

    function test_checkBatch_arrayLengthMismatch_reverts() public {
        address[] memory froms = new address[](2);
        address[] memory tos = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        address[] memory assets = new address[](2);
        bytes32[] memory namespaces = new bytes32[](2);
        IntentClass[] memory intentClasses = new IntentClass[](2);
        bytes32[] memory memoHashes = new bytes32[](1); // mismatch — 1 vs n=2

        froms[0] = PRINCIPAL; froms[1] = PRINCIPAL;
        tos[0] = RECIPIENT;   tos[1] = RECIPIENT;
        amounts[0] = 1; amounts[1] = 2;
        memoHashes[0] = MEMO;

        MandateEnvelope memory env = _stub();
        vm.expectRevert(bytes("RIVR-PH: array len"));
        hook.checkBatch(
            address(this), froms, tos, amounts, assets, namespaces,
            intentClasses, memoHashes, env
        );
    }

    function test_checkBatch_kyaInvalid_returnsKYA_INVALID() public {
        address[] memory froms = new address[](1);
        address[] memory tos = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        address[] memory assets = new address[](1);
        bytes32[] memory namespaces = new bytes32[](1);
        IntentClass[] memory intentClasses = new IntentClass[](1);
        bytes32[] memory memoHashes = new bytes32[](1);

        froms[0] = PRINCIPAL; tos[0] = RECIPIENT; amounts[0] = 1; memoHashes[0] = MEMO;

        MandateEnvelope memory env = _stub();
        env.kyaCredentialHash = keccak256("never-synced");

        (RefusalReason r, ) = hook.checkBatch(
            address(this), froms, tos, amounts, assets, namespaces,
            intentClasses, memoHashes, env
        );
        assertEq(uint8(r), uint8(RefusalReason.KYA_INVALID));
    }

    function test_checkBatch_perLegFailure_returnsLegIndexInCtx() public {
        // Two legs: leg 0 OK, leg 1 has sanctioned `from`.
        address[] memory froms = new address[](2);
        address[] memory tos = new address[](2);
        uint256[] memory amounts = new uint256[](2);
        address[] memory assets = new address[](2);
        bytes32[] memory namespaces = new bytes32[](2);
        IntentClass[] memory intentClasses = new IntentClass[](2);
        bytes32[] memory memoHashes = new bytes32[](2);

        address bad = makeAddr("bad-leg-from");
        sanctions.setSanctioned(bad, true);

        froms[0] = PRINCIPAL; froms[1] = bad;
        tos[0] = RECIPIENT;   tos[1] = RECIPIENT;
        amounts[0] = 1; amounts[1] = 1;
        memoHashes[0] = MEMO; memoHashes[1] = MEMO;

        MandateEnvelope memory env = _stub();
        (RefusalReason r, bytes32 ctx) = hook.checkBatch(
            address(this), froms, tos, amounts, assets, namespaces,
            intentClasses, memoHashes, env
        );
        assertEq(uint8(r), uint8(RefusalReason.SANCTIONS_HIT));
        // Ctx encodes the leg index (1) when a per-leg check fails.
        assertEq(ctx, bytes32(uint256(1)));
    }
}
