// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RivierTestBase} from "./Base.t.sol";
import {MandateEnvelope} from "../../src/rivier-token/types/MandateEnvelope.sol";
import {IntentClass, IntentClasses} from "../../src/rivier-token/types/IntentClass.sol";
import {RefusalReason, RivierRefused} from "../../src/rivier-token/types/RefusalReason.sol";
import {DryRunInput, DryRunLeg} from "../../src/rivier-token/types/DryRunInput.sol";
import {DryRunResult} from "../../src/rivier-token/types/DryRunResult.sol";

/// @notice The byte-equivalence invariant: for every refusal-path case,
/// `dryRun(input).reason` MUST equal the RefusalReason a real
/// `transferWithMandate(...)` would revert with. This is the load-bearing
/// agent-introspection guarantee — agents simulate before committing, so
/// the simulator that diverges from the live path is worse than no
/// simulator at all.
///
/// Each test mirrors a corresponding case in `RivierRefusalReasons.t.sol`.
/// We capture the live revert reason via low-level `try / catch
/// (bytes memory)` and decode the `RivierRefused(reason, ctx)` selector,
/// then assert `dryRun(...)` returns the same `(reason, ctx)`.
contract RivierDryRunEquivalenceTest is RivierTestBase {
    bytes32 internal constant MEMO = keccak256("memo");
    bytes internal constant EXT_DATA = "";

    function setUp() public override {
        super.setUp();
        _mintTo(PRINCIPAL, 1_000_000 * 1e18);
    }

    function _decodeRefusal(bytes memory data) internal pure returns (RefusalReason r, bytes32 ctx) {
        // RivierRefused selector + (uint256 reason, bytes32 ctx)
        require(data.length >= 4 + 32 + 32, "not a RivierRefused error");
        bytes4 sel;
        assembly {
            sel := mload(add(data, 32))
        }
        require(sel == RivierRefused.selector, "not RivierRefused");
        uint256 reasonRaw;
        bytes32 ctxRaw;
        assembly {
            reasonRaw := mload(add(data, 36))
            ctxRaw := mload(add(data, 68))
        }
        r = RefusalReason(reasonRaw);
        ctx = ctxRaw;
    }

    function _legFor(address to, uint256 amount) internal view returns (DryRunLeg memory leg) {
        leg.from = PRINCIPAL;
        leg.to = to;
        leg.amount = amount;
        leg.asset = address(token);
        leg.namespace = DEFAULT_NS;
        leg.intentClass = IntentClasses.AGENT_TO_AGENT;
        leg.memoHash = MEMO;
    }

    function _input(MandateEnvelope memory env, DryRunLeg memory leg)
        internal
        view
        returns (DryRunInput memory input)
    {
        input.legs = new DryRunLeg[](1);
        input.legs[0] = leg;
        input.mandate = env;
        input.caller = AGENT;
        input.atTimestamp = uint64(block.timestamp);
    }

    function _exec(MandateEnvelope memory env, address to, uint256 amt, uint256 amtUsd6) internal {
        vm.prank(AGENT);
        token.transferWithMandate(
            to, amt, amtUsd6, DEFAULT_NS, env,
            IntentClasses.AGENT_TO_AGENT, MEMO, EXT_DATA
        );
    }

    /// @dev Capture the live revert and dryRun verdict for the same input,
    ///      assert byte-equivalence (reason + ctx).
    function _assertEquivalent(MandateEnvelope memory env, uint256 amt, uint256 amtUsd6) internal {
        // Live path: capture revert.
        bytes memory revertData;
        bool live_reverted;
        try this._tryExec(env, RECIPIENT, amt, amtUsd6) {
            live_reverted = false;
        } catch (bytes memory data) {
            live_reverted = true;
            revertData = data;
        }
        require(live_reverted, "expected live revert");
        (RefusalReason liveR, bytes32 liveCtx) = _decodeRefusal(revertData);

        // dryRun path.
        DryRunInput memory input = _input(env, _legFor(RECIPIENT, amt));
        DryRunResult memory r = token.dryRun(input);
        assertEq(uint8(r.reason), uint8(liveR), "reason mismatch");
        assertEq(r.ctx, liveCtx, "ctx mismatch");
    }

    /// @dev External wrapper so try/catch can capture the revert.
    function _tryExec(MandateEnvelope calldata env, address to, uint256 amt, uint256 amtUsd6) external {
        vm.prank(AGENT);
        token.transferWithMandate(
            to, amt, amtUsd6, DEFAULT_NS, env,
            IntentClasses.AGENT_TO_AGENT, MEMO, EXT_DATA
        );
    }

    // ─── per-RefusalReason equivalence ──────────────────────────────

    function test_equivalence_kyaInvalid() public {
        bytes32 mid = keccak256("dre-kya");
        // KYA NOT activated.
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        _assertEquivalent(env, 1 * 1e18, 1 * 1e6);
    }

    function test_equivalence_mandateExpired_pastExpiry() public {
        bytes32 mid = keccak256("dre-expired");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        vm.warp(block.timestamp + 2 days);
        _assertEquivalent(env, 1 * 1e18, 1 * 1e6);
    }

    function test_equivalence_perTxCap() public {
        bytes32 mid = keccak256("dre-pertx");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 100 * 1e6, 10_000 * 1e6);
        _assertEquivalent(env, 200 * 1e18, 200 * 1e6);
    }

    function test_equivalence_assetNotAllowed() public {
        bytes32 mid = keccak256("dre-asset");
        _activateKya(mid);
        address[] memory allow = new address[](1);
        allow[0] = makeAddr("usdc-fake");
        MandateEnvelope memory env = _signMandate(
            mid, keccak256(abi.encode(mid, "n")), mid, allow,
            1_000 * 1e6, 10_000 * 1e6,
            uint64(block.timestamp), uint64(block.timestamp + 1 days)
        );
        _assertEquivalent(env, 1 * 1e18, 1 * 1e6);
    }

    function test_equivalence_principalSignatureInvalid() public {
        bytes32 mid = keccak256("dre-bad-sig");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        env.principalSignature = hex"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff1b";
        _assertEquivalent(env, 1 * 1e18, 1 * 1e6);
    }

    function test_equivalence_agentSignatureInvalid() public {
        bytes32 mid = keccak256("dre-bad-agent");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        env.agentSignature = hex"00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff1b";
        _assertEquivalent(env, 1 * 1e18, 1 * 1e6);
    }

    function test_equivalence_travelRuleBlock() public {
        bytes32 mid = keccak256("dre-travel");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 5_000 * 1e6, 100_000 * 1e6);
        _assertEquivalent(env, 5_000 * 1e18, 5_000 * 1e6);
    }

    function test_equivalence_sanctionsHit() public {
        bytes32 mid = keccak256("dre-sanctions");
        _activateKya(mid);
        sanctions.setSanctioned(PRINCIPAL, true);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        _assertEquivalent(env, 1 * 1e18, 1 * 1e6);
    }

    function test_equivalence_mandateRevoked_explicit() public {
        bytes32 mid = keccak256("dre-revoked");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        // First use registers + records.
        _exec(env, RECIPIENT, 1 * 1e18, 1 * 1e6);
        vm.prank(PRINCIPAL);
        mandates.revokeMandate(mid);
        // New nonce so live path's signature/replay checks both pass and
        // we hit the registry's revoked flag.
        MandateEnvelope memory env2 = _signMandate(
            mid, keccak256(abi.encode(mid, "n2")), mid, env.assetAllowlist,
            1_000 * 1e6, 10_000 * 1e6,
            uint64(block.timestamp), uint64(block.timestamp + 1 days)
        );
        _assertEquivalent(env2, 1 * 1e18, 1 * 1e6);
    }

    // ─── OK-path equivalence ────────────────────────────────────────

    function test_equivalence_okPath_dryRunReturnsOkAndLiveSucceeds() public {
        bytes32 mid = keccak256("dre-ok");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        // dryRun first: must say OK.
        DryRunInput memory input = _input(env, _legFor(RECIPIENT, 100 * 1e18));
        DryRunResult memory r = token.dryRun(input);
        assertEq(uint8(r.reason), uint8(RefusalReason.OK), "dryRun should be OK");
        // Then live exec — must succeed.
        _exec(env, RECIPIENT, 100 * 1e18, 100 * 1e6);
    }
}
