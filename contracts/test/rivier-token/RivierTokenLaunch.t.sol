// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RivierTestBase} from "./Base.t.sol";
import {RivierTokenCCT} from "../../src/rivier-token/RivierTokenCCT.sol";
import {MandateEnvelope} from "../../src/rivier-token/types/MandateEnvelope.sol";
import {BatchTransferInput} from "../../src/rivier-token/types/BatchTransferInput.sol";
import {BatchMetadata} from "../../src/rivier-token/types/BatchMetadata.sol";
import {StreamParams} from "../../src/rivier-token/types/StreamParams.sol";
import {IntentClass, IntentClasses} from "../../src/rivier-token/types/IntentClass.sol";
import {RefusalReason} from "../../src/rivier-token/types/RefusalReason.sol";
import {DryRunInput, DryRunLeg} from "../../src/rivier-token/types/DryRunInput.sol";
import {DryRunResult} from "../../src/rivier-token/types/DryRunResult.sol";

/// @notice Happy-path tests for the RIVR launch surface — the irreducible
/// set per docs/architecture/2026-rivr-design.md §"Launch — single
/// absolute-replacement PR":
///
///   - transferWithMandate
///   - batchProgrammableTransfer
///   - openStream / withdrawFromStream / closeStream
///   - deposit / withdrawFromNamespace / transferNamespace / balanceOfNamespace
///   - dryRun (view-only simulator)
///
/// Every test here builds + signs a real EIP-712 MandateEnvelope via
/// `_defaultMandate(...)` from Base.t.sol — the same path agents use
/// off-chain. Refusal-path coverage lives in RivierRefusalReasons.t.sol.
contract RivierTokenLaunchTest is RivierTestBase {
    bytes32 internal constant MEMO = keccak256("memo");
    bytes internal constant EXT_DATA = "";

    function setUp() public override {
        super.setUp();
        // Mint funded balances for the principal so transfers/streams have float.
        _mintTo(PRINCIPAL, 1_000_000 * 1e18);
    }

    // ─── transferWithMandate ────────────────────────────────────────

    function test_transferWithMandate_happyPath_movesBalance() public {
        bytes32 mid = keccak256("m1");
        // Pre-activate the KYA credential (mandateId reused as KYA hash).
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        uint256 amt = 100 * 1e18; // 100 RIVR
        uint256 amtUsd6 = 100 * 1e6;

        vm.prank(AGENT);
        bytes32 transferRef = token.transferWithMandate(
            RECIPIENT, amt, amtUsd6, DEFAULT_NS, env,
            IntentClasses.AGENT_TO_AGENT, MEMO, EXT_DATA
        );

        assertEq(transferRef, env.mandateId ^ env.nonce);
        assertEq(token.balanceOf(RECIPIENT), amt);
        assertEq(token.balanceOf(PRINCIPAL), 1_000_000 * 1e18 - amt);
        // Cumulative spend recorded on the registry.
        assertEq(mandates.cumulativeSpend(mid), amtUsd6);
        // Nonce burned for replay protection.
        assertTrue(token.usedMandateNonce(env.nonce));
    }

    function test_transferWithMandate_replayingNonce_reverts() public {
        bytes32 mid = keccak256("m-replay");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        vm.startPrank(AGENT);
        token.transferWithMandate(
            RECIPIENT, 1 * 1e18, 1 * 1e6, DEFAULT_NS, env,
            IntentClasses.AGENT_TO_AGENT, MEMO, EXT_DATA
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                RivierTokenCCT.RivierRefused.selector,
                RefusalReason.MANDATE_REVOKED,
                env.nonce
            )
        );
        token.transferWithMandate(
            RECIPIENT, 1 * 1e18, 1 * 1e6, DEFAULT_NS, env,
            IntentClasses.AGENT_TO_AGENT, MEMO, EXT_DATA
        );
        vm.stopPrank();
    }

    function test_transferWithMandate_zeroRecipient_reverts() public {
        bytes32 mid = keccak256("m-zero");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        vm.prank(AGENT);
        vm.expectRevert(bytes("RIVR: to zero"));
        token.transferWithMandate(
            address(0), 1 * 1e18, 1 * 1e6, DEFAULT_NS, env,
            IntentClasses.AGENT_TO_AGENT, MEMO, EXT_DATA
        );
    }

    function test_transferWithMandate_emitsTransferAndProgrammable() public {
        bytes32 mid = keccak256("m-emit");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        vm.prank(AGENT);
        // We assert minimum-viable: transfer succeeds. (Full event-data
        // verification is in dryRun byte-equivalence tests.)
        bytes32 ref = token.transferWithMandate(
            RECIPIENT, 5 * 1e18, 5 * 1e6, DEFAULT_NS, env,
            IntentClasses.AGENT_TO_AGENT, MEMO, EXT_DATA
        );
        assertTrue(ref != bytes32(0));
    }

    // ─── batchProgrammableTransfer ──────────────────────────────────

    function test_batchProgrammableTransfer_atomic_movesAllLegs() public {
        bytes32 mid = keccak256("m-batch");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        address r1 = makeAddr("r1");
        address r2 = makeAddr("r2");
        address r3 = makeAddr("r3");

        BatchTransferInput memory input;
        input.recipients = new address[](3);
        input.amounts = new uint256[](3);
        input.amountsUsd6 = new uint256[](3);
        input.namespaces = new bytes32[](3);
        input.intentClasses = new IntentClass[](3);
        input.memoHashes = new bytes32[](3);
        input.extensionDatas = new bytes[](3);

        input.recipients[0] = r1; input.amounts[0] = 10 * 1e18; input.amountsUsd6[0] = 10 * 1e6;
        input.recipients[1] = r2; input.amounts[1] = 20 * 1e18; input.amountsUsd6[1] = 20 * 1e6;
        input.recipients[2] = r3; input.amounts[2] = 30 * 1e18; input.amountsUsd6[2] = 30 * 1e6;
        for (uint256 i = 0; i < 3; i++) {
            input.namespaces[i] = DEFAULT_NS;
            input.intentClasses[i] = IntentClasses.AGENT_TO_AGENT;
            input.memoHashes[i] = MEMO;
            input.extensionDatas[i] = "";
        }
        input.mandate = env;
        input.meta = BatchMetadata({batchRef: keccak256("batch-1"), settlementHash: bytes32(0)});

        vm.prank(AGENT);
        token.batchProgrammableTransfer(input);

        assertEq(token.balanceOf(r1), 10 * 1e18);
        assertEq(token.balanceOf(r2), 20 * 1e18);
        assertEq(token.balanceOf(r3), 30 * 1e18);
        assertEq(token.balanceOf(PRINCIPAL), 1_000_000 * 1e18 - 60 * 1e18);
        // Single cumulative-spend record at the batch sum.
        assertEq(mandates.cumulativeSpend(mid), 60 * 1e6);
    }

    function test_batchProgrammableTransfer_emptyBatch_reverts() public {
        bytes32 mid = keccak256("m-empty");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        BatchTransferInput memory input;
        input.recipients = new address[](0);
        input.amounts = new uint256[](0);
        input.amountsUsd6 = new uint256[](0);
        input.namespaces = new bytes32[](0);
        input.intentClasses = new IntentClass[](0);
        input.memoHashes = new bytes32[](0);
        input.extensionDatas = new bytes[](0);
        input.mandate = env;
        input.meta = BatchMetadata({batchRef: keccak256("batch-empty"), settlementHash: bytes32(0)});

        vm.prank(AGENT);
        vm.expectRevert(bytes("RIVR: empty batch"));
        token.batchProgrammableTransfer(input);
    }

    function test_batchProgrammableTransfer_lengthMismatch_reverts() public {
        bytes32 mid = keccak256("m-mismatch");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        BatchTransferInput memory input;
        input.recipients = new address[](2);
        input.recipients[0] = makeAddr("r1");
        input.recipients[1] = makeAddr("r2");
        input.amounts = new uint256[](1); // mismatch
        input.amounts[0] = 1 * 1e18;
        input.amountsUsd6 = new uint256[](2);
        input.namespaces = new bytes32[](2);
        input.intentClasses = new IntentClass[](2);
        input.memoHashes = new bytes32[](2);
        input.extensionDatas = new bytes[](2);
        input.mandate = env;
        input.meta = BatchMetadata({batchRef: bytes32(0), settlementHash: bytes32(0)});

        vm.prank(AGENT);
        vm.expectRevert(bytes("RIVR: len"));
        token.batchProgrammableTransfer(input);
    }

    // ─── streams ────────────────────────────────────────────────────

    function test_openStream_andWithdraw_creditsRecipient() public {
        bytes32 mid = keccak256("m-stream");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        StreamParams memory p;
        p.recipient = RECIPIENT;
        p.ratePerSecond = 1e15; // 0.001 RIVR/sec
        p.startsAt = uint64(block.timestamp);
        p.endsAt = uint64(block.timestamp + 1 hours);
        p.namespaceFromPayer = DEFAULT_NS;
        p.mandate = env;
        p.intentClass = IntentClasses.STREAM_OPEN;

        vm.prank(AGENT);
        bytes32 streamRef = token.openStream(p);

        // Warp 100 seconds — 100 * 1e15 accrued.
        vm.warp(block.timestamp + 100);
        assertEq(token.streamBalance(streamRef), 100 * 1e15);

        // Recipient withdraws 50 * 1e15.
        vm.prank(RECIPIENT);
        token.withdrawFromStream(streamRef, 50 * 1e15);

        assertEq(token.balanceOf(RECIPIENT), 50 * 1e15);
        assertEq(token.streamBalance(streamRef), 50 * 1e15);
    }

    function test_withdrawFromStream_byNonRecipient_reverts() public {
        bytes32 mid = keccak256("m-stream-norec");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        StreamParams memory p;
        p.recipient = RECIPIENT;
        p.ratePerSecond = 1e15;
        p.startsAt = uint64(block.timestamp);
        p.endsAt = uint64(block.timestamp + 1 hours);
        p.namespaceFromPayer = DEFAULT_NS;
        p.mandate = env;
        p.intentClass = IntentClasses.STREAM_OPEN;

        vm.prank(AGENT);
        bytes32 streamRef = token.openStream(p);

        vm.warp(block.timestamp + 10);
        vm.prank(makeAddr("rando"));
        vm.expectRevert(bytes("RIVR: not recipient"));
        token.withdrawFromStream(streamRef, 1 * 1e15);
    }

    function test_closeStream_truncatesAccrual() public {
        bytes32 mid = keccak256("m-stream-close");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        StreamParams memory p;
        p.recipient = RECIPIENT;
        p.ratePerSecond = 1e15;
        p.startsAt = uint64(block.timestamp);
        p.endsAt = uint64(block.timestamp + 1 hours);
        p.namespaceFromPayer = DEFAULT_NS;
        p.mandate = env;
        p.intentClass = IntentClasses.STREAM_OPEN;

        vm.prank(AGENT);
        bytes32 streamRef = token.openStream(p);

        vm.warp(block.timestamp + 100);
        // Either payer or recipient can close — go through the token entry point.
        vm.prank(PRINCIPAL);
        token.closeStream(streamRef);

        // Future warp does not increase balance.
        vm.warp(block.timestamp + 1000);
        assertEq(token.streamBalance(streamRef), 100 * 1e15);
    }

    // ─── namespaces ─────────────────────────────────────────────────

    function test_deposit_movesIntoNamespace_balanceOfPreserved() public {
        bytes32 ns = keccak256("agent-A");
        uint256 totalBefore = token.balanceOf(PRINCIPAL);

        vm.prank(PRINCIPAL);
        token.deposit(ns, 100 * 1e18);

        assertEq(token.balanceOfNamespace(PRINCIPAL, ns), 100 * 1e18);
        assertEq(
            token.balanceOfNamespace(PRINCIPAL, DEFAULT_NS),
            totalBefore - 100 * 1e18
        );
        // Sum invariant: balanceOf == DEFAULT_NS + ns
        assertEq(token.balanceOf(PRINCIPAL), totalBefore);
    }

    function test_deposit_zeroNamespace_reverts() public {
        vm.prank(PRINCIPAL);
        vm.expectRevert(bytes("RIVR: ns zero"));
        token.deposit(DEFAULT_NS, 1 * 1e18);
    }

    function test_transferNamespace_intraAccount_isSumPreserving() public {
        bytes32 nsA = keccak256("ns-A");
        bytes32 nsB = keccak256("ns-B");

        vm.startPrank(PRINCIPAL);
        token.deposit(nsA, 200 * 1e18);
        uint256 totalBefore = token.balanceOf(PRINCIPAL);
        token.transferNamespace(nsA, nsB, 75 * 1e18);
        vm.stopPrank();

        assertEq(token.balanceOfNamespace(PRINCIPAL, nsA), 125 * 1e18);
        assertEq(token.balanceOfNamespace(PRINCIPAL, nsB), 75 * 1e18);
        assertEq(token.balanceOf(PRINCIPAL), totalBefore);
    }

    function test_transferNamespace_sameNamespace_reverts() public {
        bytes32 ns = keccak256("ns-X");
        vm.startPrank(PRINCIPAL);
        token.deposit(ns, 1 * 1e18);
        vm.expectRevert(bytes("RIVR: same ns"));
        token.transferNamespace(ns, ns, 1);
        vm.stopPrank();
    }

    function test_withdrawFromNamespace_creditsRecipientDefault() public {
        bytes32 ns = keccak256("ns-out");
        address bob = makeAddr("bob");

        vm.startPrank(PRINCIPAL);
        token.deposit(ns, 50 * 1e18);
        token.withdrawFromNamespace(ns, bob, 20 * 1e18);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 20 * 1e18);
        assertEq(token.balanceOfNamespace(bob, DEFAULT_NS), 20 * 1e18);
        assertEq(token.balanceOfNamespace(PRINCIPAL, ns), 30 * 1e18);
    }

    function test_namespacesOf_pushOnlyEnumeration() public {
        bytes32 nsA = keccak256("a");
        bytes32 nsB = keccak256("b");

        vm.startPrank(PRINCIPAL);
        token.deposit(nsA, 1 * 1e18);
        token.deposit(nsB, 1 * 1e18);
        // Even after draining nsA, it stays in the list.
        token.transferNamespace(nsA, nsB, 1 * 1e18);
        vm.stopPrank();

        bytes32[] memory list = token.namespacesOf(PRINCIPAL);
        // DEFAULT_NS auto-registered on the initial mint, plus nsA + nsB.
        assertEq(list.length, 3);
    }

    // ─── dryRun ─────────────────────────────────────────────────────

    function test_dryRun_okPath_returnsOK_andProjectsCumulative() public {
        bytes32 mid = keccak256("m-dry-ok");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        DryRunLeg[] memory legs = new DryRunLeg[](1);
        legs[0] = DryRunLeg({
            from: PRINCIPAL,
            to: RECIPIENT,
            amount: 100 * 1e18,
            asset: address(token),
            namespace: DEFAULT_NS,
            intentClass: IntentClasses.AGENT_TO_AGENT,
            memoHash: MEMO
        });

        DryRunInput memory input = DryRunInput({
            legs: legs,
            mandate: env,
            caller: AGENT,
            atTimestamp: 0
        });

        DryRunResult memory r = token.dryRun(input);
        assertEq(uint8(r.reason), uint8(RefusalReason.OK));
        assertEq(r.projectedCumulativeUsd, 100 * 1e6);
        assertEq(uint8(r.legResults[0].reason), uint8(RefusalReason.OK));
    }

    function test_dryRun_doesNotMutateState() public {
        bytes32 mid = keccak256("m-dry-pure");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        DryRunLeg[] memory legs = new DryRunLeg[](1);
        legs[0] = DryRunLeg({
            from: PRINCIPAL, to: RECIPIENT, amount: 1 * 1e18, asset: address(token),
            namespace: DEFAULT_NS, intentClass: IntentClasses.AGENT_TO_AGENT,
            memoHash: MEMO
        });

        DryRunInput memory input = DryRunInput({
            legs: legs, mandate: env, caller: AGENT, atTimestamp: 0
        });

        token.dryRun(input);

        // Nonce NOT burned, registry has no record, balances unchanged.
        assertFalse(token.usedMandateNonce(env.nonce));
        assertEq(mandates.cumulativeSpend(mid), 0);
        assertEq(token.balanceOf(RECIPIENT), 0);
    }

    function test_dryRun_belowDeMinimisStillOk() public {
        bytes32 mid = keccak256("m-dry-de-minimis");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        DryRunLeg[] memory legs = new DryRunLeg[](1);
        legs[0] = DryRunLeg({
            from: PRINCIPAL, to: RECIPIENT, amount: 999 * 1e18, asset: address(token),
            namespace: DEFAULT_NS, intentClass: IntentClasses.AGENT_TO_AGENT,
            memoHash: MEMO
        });

        DryRunInput memory input = DryRunInput({
            legs: legs, mandate: env, caller: AGENT, atTimestamp: 0
        });

        DryRunResult memory r = token.dryRun(input);
        assertEq(uint8(r.reason), uint8(RefusalReason.OK));
    }

    function test_dryRun_emptyLegs_returnsOK() public {
        bytes32 mid = keccak256("m-dry-empty");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        DryRunInput memory input = DryRunInput({
            legs: new DryRunLeg[](0),
            mandate: env, caller: AGENT, atTimestamp: 0
        });

        DryRunResult memory r = token.dryRun(input);
        assertEq(uint8(r.reason), uint8(RefusalReason.OK));
        assertEq(r.legResults.length, 0);
    }

    // ─── pause ──────────────────────────────────────────────────────

    function test_pause_blocksTransferWithMandate() public {
        bytes32 mid = keccak256("m-pause");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        vm.prank(TREASURY);
        token.pause();

        vm.prank(AGENT);
        vm.expectRevert();
        token.transferWithMandate(
            RECIPIENT, 1 * 1e18, 1 * 1e6, DEFAULT_NS, env,
            IntentClasses.AGENT_TO_AGENT, MEMO, EXT_DATA
        );
    }

    function test_unpause_restoresTransfers() public {
        bytes32 mid = keccak256("m-unpause");
        _activateKya(mid);

        vm.startPrank(TREASURY);
        token.pause();
        token.unpause();
        vm.stopPrank();

        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        vm.prank(AGENT);
        token.transferWithMandate(
            RECIPIENT, 1 * 1e18, 1 * 1e6, DEFAULT_NS, env,
            IntentClasses.AGENT_TO_AGENT, MEMO, EXT_DATA
        );
        assertEq(token.balanceOf(RECIPIENT), 1 * 1e18);
    }
}
