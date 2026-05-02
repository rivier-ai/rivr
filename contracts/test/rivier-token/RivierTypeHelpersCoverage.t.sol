// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MandateEnvelope, MandateEnvelopeLib} from "../../src/rivier-token/types/MandateEnvelope.sol";
import {IntentClass, IntentClasses} from "../../src/rivier-token/types/IntentClass.sol";

/// @notice Direct coverage for the type-library helpers
///         (MandateEnvelopeLib.assetAllowed branches + IntentClasses.unwrap/eq).
///         These libraries have no state and aren't exercised by the
///         transferring-path suites, so they need their own targeted tests.
contract RivierTypeHelpersCoverageTest is Test {
    address internal constant ANY_ASSET = address(0);

    /// @dev Wrapper that forwards calldata into the calldata-only library helper.
    function _assetAllowed(MandateEnvelope calldata env, address asset) external pure returns (bool) {
        return MandateEnvelopeLib.assetAllowed(env, asset);
    }

    /// @dev Wrapper for the calldata-keyed structHash helper.
    function _structHash(MandateEnvelope calldata env) external pure returns (bytes32) {
        return MandateEnvelopeLib.structHash(env);
    }

    function _emptyEnvelope() internal pure returns (MandateEnvelope memory env) {
        env.principal = address(0xA1);
        env.agent = address(0xA2);
        env.maxPerTxUsd = 1;
        env.maxTotalUsd = 1;
        env.notBefore = 0;
        env.expiresAt = type(uint64).max;
        env.mandateId = bytes32(uint256(1));
        env.nonce = bytes32(uint256(2));
        env.kyaCredentialHash = bytes32(uint256(3));
        env.principalSignature = bytes("");
        env.agentSignature = bytes("");
    }

    // ─── MandateEnvelopeLib.assetAllowed branches ────────────────────────────

    function test_assetAllowed_anySentinel_matchesEverything() public view {
        MandateEnvelope memory env = _emptyEnvelope();
        env.assetAllowlist = new address[](1);
        env.assetAllowlist[0] = ANY_ASSET;

        // Sentinel path: len==1 && [0]==ANY_ASSET — must return true for any asset.
        assertTrue(this._assetAllowed(env, address(0xBEEF)));
        assertTrue(this._assetAllowed(env, address(0xCAFE)));
    }

    function test_assetAllowed_explicit_match() public view {
        MandateEnvelope memory env = _emptyEnvelope();
        env.assetAllowlist = new address[](2);
        env.assetAllowlist[0] = address(0xAAAA);
        env.assetAllowlist[1] = address(0xBBBB);

        assertTrue(this._assetAllowed(env, address(0xAAAA)));
        assertTrue(this._assetAllowed(env, address(0xBBBB)));
    }

    function test_assetAllowed_explicit_noMatch() public view {
        MandateEnvelope memory env = _emptyEnvelope();
        env.assetAllowlist = new address[](2);
        env.assetAllowlist[0] = address(0xAAAA);
        env.assetAllowlist[1] = address(0xBBBB);

        // Loop completes without match — must return false.
        assertFalse(this._assetAllowed(env, address(0xCCCC)));
    }

    function test_assetAllowed_emptyList_noMatch() public view {
        MandateEnvelope memory env = _emptyEnvelope();
        env.assetAllowlist = new address[](0);

        // len==0 — sentinel guard skipped, loop doesn't execute, returns false.
        assertFalse(this._assetAllowed(env, address(0xAAAA)));
    }

    function test_assetAllowed_singleZero_isSentinelNotExplicit() public view {
        MandateEnvelope memory env = _emptyEnvelope();
        env.assetAllowlist = new address[](1);
        env.assetAllowlist[0] = ANY_ASSET; // address(0) == ANY_ASSET sentinel

        // [address(0)] alone is the wildcard sentinel.
        assertTrue(this._assetAllowed(env, address(0xBEEF)));
    }

    function test_assetAllowed_zeroInLargerList_doesNotTriggerSentinel() public view {
        MandateEnvelope memory env = _emptyEnvelope();
        env.assetAllowlist = new address[](2);
        env.assetAllowlist[0] = ANY_ASSET;
        env.assetAllowlist[1] = address(0xAAAA);

        // len > 1 — sentinel guard NOT triggered. Now address(0) is just an explicit
        // entry; querying for arbitrary address that doesn't match returns false.
        assertFalse(this._assetAllowed(env, address(0xBEEF)));
        // But querying address(0) directly matches by explicit equality.
        assertTrue(this._assetAllowed(env, address(0)));
        // And the other explicit entry still matches.
        assertTrue(this._assetAllowed(env, address(0xAAAA)));
    }

    // ─── MandateEnvelopeLib.structHash deterministic ─────────────────────────

    function test_structHash_isDeterministic() public view {
        MandateEnvelope memory env = _emptyEnvelope();
        env.assetAllowlist = new address[](2);
        env.assetAllowlist[0] = address(0xA1);
        env.assetAllowlist[1] = address(0xA2);

        bytes32 a = this._structHash(env);
        bytes32 b = this._structHash(env);
        assertEq(a, b, "structHash must be deterministic");
        assertTrue(a != bytes32(0));
    }

    function test_structHash_differs_onAllowlistChange() public view {
        MandateEnvelope memory env1 = _emptyEnvelope();
        env1.assetAllowlist = new address[](1);
        env1.assetAllowlist[0] = address(0xA1);

        MandateEnvelope memory env2 = _emptyEnvelope();
        env2.assetAllowlist = new address[](1);
        env2.assetAllowlist[0] = address(0xA2);

        bytes32 h1 = this._structHash(env1);
        bytes32 h2 = this._structHash(env2);
        assertTrue(h1 != h2, "different allowlist must produce different hash");
    }

    // ─── IntentClasses helpers ───────────────────────────────────────────────

    function test_intentClass_unwrap() public pure {
        assertEq(IntentClasses.unwrap(IntentClasses.UNSPECIFIED), 0x00);
        assertEq(IntentClasses.unwrap(IntentClasses.AGENT_TO_AGENT), 0x02);
        assertEq(IntentClasses.unwrap(IntentClasses.STREAM_OPEN), 0x08);
        assertEq(IntentClasses.unwrap(IntentClasses.SUBSCRIPTION_CHARGE), 0x10);
        assertEq(IntentClasses.unwrap(IntentClasses.CROSS_CHAIN_BURN_MINT), 0x15);
    }

    function test_intentClass_eq_true() public pure {
        IntentClass a = IntentClasses.AGENT_TO_AGENT;
        IntentClass b = IntentClasses.AGENT_TO_AGENT;
        assertTrue(IntentClasses.eq(a, b));
    }

    function test_intentClass_eq_false() public pure {
        IntentClass a = IntentClasses.AGENT_TO_AGENT;
        IntentClass b = IntentClasses.STREAM_OPEN;
        assertFalse(IntentClasses.eq(a, b));
    }
}
