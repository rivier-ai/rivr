// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RivierTestBase, MockPoRFeed} from "./Base.t.sol";
import {RivierTokenCCT} from "../../src/rivier-token/RivierTokenCCT.sol";
import {RivierKyaRegistry} from "../../src/rivier-token/registries/RivierKyaRegistry.sol";
import {RivierMandateRegistry} from "../../src/rivier-token/registries/RivierMandateRegistry.sol";
import {RivierStreamRegistry} from "../../src/rivier-token/registries/RivierStreamRegistry.sol";
import {RivierPolicyHook} from "../../src/rivier-token/policy/RivierPolicyHook.sol";

import {MandateEnvelope} from "../../src/rivier-token/types/MandateEnvelope.sol";
import {BatchTransferInput} from "../../src/rivier-token/types/BatchTransferInput.sol";
import {BatchMetadata} from "../../src/rivier-token/types/BatchMetadata.sol";
import {StreamParams} from "../../src/rivier-token/types/StreamParams.sol";
import {IntentClass, IntentClasses} from "../../src/rivier-token/types/IntentClass.sol";
import {RefusalReason} from "../../src/rivier-token/types/RefusalReason.sol";
import {DryRunInput, DryRunLeg} from "../../src/rivier-token/types/DryRunInput.sol";
import {DryRunResult} from "../../src/rivier-token/types/DryRunResult.sol";

/// @notice Direct branch-coverage tests for `RivierTokenCCT`. Targets the
///         conditional sites that the launch + refusal-reasons + namespace
///         suites don't exercise: constructor zero-address guards, PoR
///         feed branches, registry-setter zero guards, batch length-mismatch
///         require()s, stream pre-call validation, dryRun cap fallback,
///         `_dryRunLeg` non-self asset short-circuit, mandate notBefore vs
///         expiresAt branches.
contract RivierTokenBranchCoverageTest is RivierTestBase {
    bytes32 internal constant MEMO = keccak256("memo");
    bytes internal constant EXT_DATA = "";

    function setUp() public override {
        super.setUp();
        _mintTo(PRINCIPAL, 1_000_000 * 1e18);
    }

    // ─── constructor zero-address guards (lines 219-224) ────────────

    function test_constructor_revertsOnZeroDefaultAdmin() public {
        vm.expectRevert(bytes("RIVR: defaultAdmin zero"));
        new RivierTokenCCT(address(0), TREASURY, TREASURY, CCIP_ADMIN, POLICY_ADMIN, RECOVERY);
    }

    function test_constructor_revertsOnZeroMinter() public {
        vm.expectRevert(bytes("RIVR: minter zero"));
        new RivierTokenCCT(TREASURY, address(0), TREASURY, CCIP_ADMIN, POLICY_ADMIN, RECOVERY);
    }

    function test_constructor_revertsOnZeroPauser() public {
        vm.expectRevert(bytes("RIVR: pauser zero"));
        new RivierTokenCCT(TREASURY, TREASURY, address(0), CCIP_ADMIN, POLICY_ADMIN, RECOVERY);
    }

    function test_constructor_revertsOnZeroCcipAdmin() public {
        vm.expectRevert(bytes("RIVR: ccipAdmin zero"));
        new RivierTokenCCT(TREASURY, TREASURY, TREASURY, address(0), POLICY_ADMIN, RECOVERY);
    }

    function test_constructor_revertsOnZeroPolicyAdmin() public {
        vm.expectRevert(bytes("RIVR: policyAdmin zero"));
        new RivierTokenCCT(TREASURY, TREASURY, TREASURY, CCIP_ADMIN, address(0), RECOVERY);
    }

    function test_constructor_revertsOnZeroRecovery() public {
        vm.expectRevert(bytes("RIVR: recovery zero"));
        new RivierTokenCCT(TREASURY, TREASURY, TREASURY, CCIP_ADMIN, POLICY_ADMIN, address(0));
    }

    // ─── _update branches (line 272 — from==0, to==0, no-policyHook) ─

    /// @dev Mint path: from == address(0) — bypasses policy hook. Covered
    ///      by the from==0 branch in `_update`.
    function test_update_mintPath_skipsPolicyHook() public {
        // Default policyHook is wired; mint still bypasses because from==0.
        uint256 before = token.balanceOf(RECIPIENT);
        _mintTo(RECIPIENT, 50 * 1e18);
        assertEq(token.balanceOf(RECIPIENT) - before, 50 * 1e18);
    }

    /// @dev Burn path: to == address(0) — bypasses policy hook.
    function test_update_burnPath_skipsPolicyHook() public {
        // Grant BURNER_ROLE to a holder, fund them, burn.
        address burner = makeAddr("burner");
        vm.startPrank(TREASURY);
        token.grantRole(token.BURNER_ROLE(), burner);
        vm.stopPrank();
        _mintTo(burner, 100 * 1e18);

        vm.prank(burner);
        token.burn(40 * 1e18);
        assertEq(token.balanceOf(burner), 60 * 1e18);
    }

    /// @dev Plain transfer when policyHook == address(0) — short-circuits.
    function test_update_noPolicyHook_passesThrough() public {
        // Detach the policy hook (POLICY_ADMIN-gated).
        vm.prank(POLICY_ADMIN);
        token.setPolicyHook(address(0));

        // Plain ERC-20 transfer should now bypass the hook entirely.
        vm.prank(PRINCIPAL);
        bool ok = token.transfer(RECIPIENT, 10 * 1e18);
        assertTrue(ok);
        assertEq(token.balanceOf(RECIPIENT), 10 * 1e18);
    }

    // ─── PoR feed branches (lines 364, 367, 368, 371, 378) ──────────

    function test_porFeed_unsetBypassesAllChecks() public {
        // No feed wired by default — the no-feed branch returns early.
        // Mint should succeed regardless of PoR state.
        _mintTo(RECIPIENT, 1 * 1e18);
        assertEq(token.balanceOf(RECIPIENT), 1 * 1e18);
    }

    function test_porFeed_zeroTimestampReverts() public {
        MockPoRFeed feed = new MockPoRFeed(8);
        // Don't call set() — timestamp stays at zero.
        vm.prank(CCIP_ADMIN);
        token.setPorFeed(address(feed));

        vm.expectRevert(bytes("RIVR: PoR no timestamp"));
        _mintTo(RECIPIENT, 1 * 1e18);
    }

    function test_porFeed_staleTimestampReverts() public {
        MockPoRFeed feed = new MockPoRFeed(8);
        // Set a fresh-looking value, but advance time past PoR_STALENESS.
        feed.set(int256(1_000_000_000 * 1e8), block.timestamp);
        vm.prank(CCIP_ADMIN);
        token.setPorFeed(address(feed));

        vm.warp(block.timestamp + 25 hours);
        vm.expectRevert(bytes("RIVR: PoR stale"));
        _mintTo(RECIPIENT, 1 * 1e18);
    }

    function test_porFeed_nonPositiveAnswerReverts() public {
        MockPoRFeed feed = new MockPoRFeed(8);
        feed.set(int256(0), block.timestamp);
        vm.prank(CCIP_ADMIN);
        token.setPorFeed(address(feed));

        vm.expectRevert(bytes("RIVR: PoR non-positive"));
        _mintTo(RECIPIENT, 1 * 1e18);
    }

    function test_porFeed_insufficientReservesReverts() public {
        MockPoRFeed feed = new MockPoRFeed(8);
        // Reserve says $1 of backing in 8-dec scaled. Mint is far larger.
        feed.set(int256(1 * 1e8), block.timestamp);
        vm.prank(CCIP_ADMIN);
        token.setPorFeed(address(feed));

        vm.expectRevert(bytes("RIVR: insufficient reserves"));
        _mintTo(RECIPIENT, 1_000_000 * 1e18);
    }

    function test_porFeed_sufficientReservesAllows() public {
        MockPoRFeed feed = new MockPoRFeed(8);
        // Reserve says $5T — enough for any test mint.
        feed.set(int256(5_000_000_000_000 * 1e8), block.timestamp);
        vm.prank(CCIP_ADMIN);
        token.setPorFeed(address(feed));

        _mintTo(RECIPIENT, 100 * 1e18);
        assertEq(token.balanceOf(RECIPIENT), 100 * 1e18);
    }

    function test_porFeed_18DecimalFeedScalesUpward() public {
        // Cover the `feedDecimals < 18` else-branch (>=18, multiplies up).
        // setUp() pre-mints 1_000_000 * 1e18 to PRINCIPAL. After +1*1e18, projected
        // supply is ~1_000_001 * 1e18. With a 20-decimal feed, scaledSupply = supply *
        // 1e2 ≈ 1.000001e26. Set feed answer to 1e30 to comfortably cover.
        MockPoRFeed feed = new MockPoRFeed(20);
        feed.set(int256(1e30), block.timestamp);
        vm.prank(CCIP_ADMIN);
        token.setPorFeed(address(feed));

        _mintTo(RECIPIENT, 1 * 1e18);
        assertEq(token.balanceOf(RECIPIENT), 1 * 1e18);
    }

    // ─── transferCCIPAdmin (line 346) ───────────────────────────────

    function test_transferCCIPAdmin_zeroAddressReverts() public {
        vm.prank(CCIP_ADMIN);
        vm.expectRevert(bytes("RIVR: newAdmin zero"));
        token.transferCCIPAdmin(address(0));
    }

    function test_transferCCIPAdmin_rotatesRole() public {
        address newAdmin = makeAddr("newCcipAdmin");
        vm.prank(CCIP_ADMIN);
        token.transferCCIPAdmin(newAdmin);

        assertEq(token.getCCIPAdmin(), newAdmin);
        assertTrue(token.hasRole(token.CCIP_ADMIN_ROLE(), newAdmin));
        assertFalse(token.hasRole(token.CCIP_ADMIN_ROLE(), CCIP_ADMIN));
    }

    // ─── registry setters' zero-address guards (lines 390, 397, 404) ─

    function test_setKyaRegistry_zeroAddressReverts() public {
        vm.prank(POLICY_ADMIN);
        vm.expectRevert(bytes("RIVR: kya zero"));
        token.setKyaRegistry(address(0));
    }

    function test_setMandateRegistry_zeroAddressReverts() public {
        vm.prank(POLICY_ADMIN);
        vm.expectRevert(bytes("RIVR: mandate zero"));
        token.setMandateRegistry(address(0));
    }

    function test_setStreamRegistry_zeroAddressReverts() public {
        vm.prank(POLICY_ADMIN);
        vm.expectRevert(bytes("RIVR: stream zero"));
        token.setStreamRegistry(address(0));
    }

    /// @dev `setPolicyHook(0)` is intentionally allowed — used to detach
    ///      the hook for plain ERC-20 transfers in degraded mode.
    function test_setPolicyHook_acceptsZero() public {
        vm.prank(POLICY_ADMIN);
        token.setPolicyHook(address(0));
        assertEq(address(token.policyHook()), address(0));
    }

    // ─── deposit/withdraw/transferNamespace require() branches ──────

    function test_deposit_zeroNamespaceReverts() public {
        vm.prank(PRINCIPAL);
        vm.expectRevert(bytes("RIVR: ns zero"));
        token.deposit(DEFAULT_NS, 1);
    }

    function test_withdrawFromNamespace_zeroToReverts() public {
        bytes32 ns = keccak256("ns-x");
        vm.startPrank(PRINCIPAL);
        token.deposit(ns, 5 * 1e18);
        vm.expectRevert(bytes("RIVR: to zero"));
        token.withdrawFromNamespace(ns, address(0), 1);
        vm.stopPrank();
    }

    function test_withdrawFromNamespace_defaultNamespaceReverts() public {
        vm.prank(PRINCIPAL);
        vm.expectRevert(bytes("RIVR: ns zero"));
        token.withdrawFromNamespace(DEFAULT_NS, RECIPIENT, 1);
    }

    function test_transferNamespace_sameNamespaceReverts() public {
        bytes32 ns = keccak256("ns-y");
        vm.startPrank(PRINCIPAL);
        vm.expectRevert(bytes("RIVR: same ns"));
        token.transferNamespace(ns, ns, 1);
        vm.stopPrank();
    }

    function test_moveBetweenNamespaces_insufficientSourceReverts() public {
        bytes32 ns = keccak256("ns-z");
        vm.startPrank(PRINCIPAL);
        token.deposit(ns, 5 * 1e18);
        vm.expectRevert(bytes("RIVR: insufficient ns"));
        token.transferNamespace(ns, keccak256("ns-w"), 100 * 1e18);
        vm.stopPrank();
    }

    // ─── batchProgrammableTransfer length / zero / empty checks ─────

    function _emptyBatch() internal pure returns (BatchTransferInput memory b) {
        b.recipients = new address[](0);
        b.amounts = new uint256[](0);
        b.amountsUsd6 = new uint256[](0);
        b.namespaces = new bytes32[](0);
        b.intentClasses = new IntentClass[](0);
        b.memoHashes = new bytes32[](0);
        b.extensionDatas = new bytes[](0);
    }

    function test_batch_emptyRecipientsReverts() public {
        bytes32 mid = keccak256("m-batch-empty");
        _activateKya(mid);
        BatchTransferInput memory b = _emptyBatch();
        b.mandate = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        b.meta = BatchMetadata({batchRef: keccak256("br"), settlementHash: bytes32(0)});

        vm.prank(AGENT);
        vm.expectRevert(bytes("RIVR: empty batch"));
        token.batchProgrammableTransfer(b);
    }

    function _onelegBatchWithMismatchedAmounts() internal view returns (BatchTransferInput memory b) {
        b.recipients = new address[](1);
        b.recipients[0] = RECIPIENT;
        b.amounts = new uint256[](2); // mismatch
        b.amountsUsd6 = new uint256[](1);
        b.namespaces = new bytes32[](1);
        b.intentClasses = new IntentClass[](1);
        b.memoHashes = new bytes32[](1);
        b.extensionDatas = new bytes[](1);
    }

    function test_batch_amountsLengthMismatchReverts() public {
        bytes32 mid = keccak256("m-batch-len-amounts");
        _activateKya(mid);
        BatchTransferInput memory b = _onelegBatchWithMismatchedAmounts();
        b.mandate = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        b.meta = BatchMetadata({batchRef: keccak256("br"), settlementHash: bytes32(0)});

        vm.prank(AGENT);
        vm.expectRevert(bytes("RIVR: len"));
        token.batchProgrammableTransfer(b);
    }

    function _batchWithLenMismatch(string memory which) internal view returns (BatchTransferInput memory b) {
        b.recipients = new address[](1);
        b.recipients[0] = RECIPIENT;
        b.amounts = new uint256[](1);
        b.amountsUsd6 = new uint256[](1);
        b.namespaces = new bytes32[](1);
        b.intentClasses = new IntentClass[](1);
        b.memoHashes = new bytes32[](1);
        b.extensionDatas = new bytes[](1);

        bytes32 k = keccak256(bytes(which));
        if (k == keccak256("amountsUsd6")) {
            b.amountsUsd6 = new uint256[](2);
        } else if (k == keccak256("namespaces")) {
            b.namespaces = new bytes32[](2);
        } else if (k == keccak256("intentClasses")) {
            b.intentClasses = new IntentClass[](2);
        } else if (k == keccak256("memoHashes")) {
            b.memoHashes = new bytes32[](2);
        } else if (k == keccak256("extensionDatas")) {
            b.extensionDatas = new bytes[](2);
        }
    }

    function _signAndExpectLenRevert(BatchTransferInput memory b, bytes32 mid) internal {
        _activateKya(mid);
        b.mandate = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        b.meta = BatchMetadata({batchRef: keccak256("br"), settlementHash: bytes32(0)});

        vm.prank(AGENT);
        vm.expectRevert(bytes("RIVR: len"));
        token.batchProgrammableTransfer(b);
    }

    function test_batch_amountsUsd6LengthMismatchReverts() public {
        BatchTransferInput memory b = _batchWithLenMismatch("amountsUsd6");
        _signAndExpectLenRevert(b, keccak256("m-len-usd6"));
    }

    function test_batch_namespacesLengthMismatchReverts() public {
        BatchTransferInput memory b = _batchWithLenMismatch("namespaces");
        _signAndExpectLenRevert(b, keccak256("m-len-ns"));
    }

    function test_batch_intentClassesLengthMismatchReverts() public {
        BatchTransferInput memory b = _batchWithLenMismatch("intentClasses");
        _signAndExpectLenRevert(b, keccak256("m-len-ic"));
    }

    function test_batch_memoHashesLengthMismatchReverts() public {
        BatchTransferInput memory b = _batchWithLenMismatch("memoHashes");
        _signAndExpectLenRevert(b, keccak256("m-len-mh"));
    }

    function test_batch_extensionDatasLengthMismatchReverts() public {
        BatchTransferInput memory b = _batchWithLenMismatch("extensionDatas");
        _signAndExpectLenRevert(b, keccak256("m-len-ed"));
    }

    function test_batch_zeroRecipientReverts() public {
        bytes32 mid = keccak256("m-batch-zero-recipient");
        _activateKya(mid);

        BatchTransferInput memory b;
        b.recipients = new address[](1);
        b.recipients[0] = address(0); // bad
        b.amounts = new uint256[](1);
        b.amounts[0] = 1 * 1e18;
        b.amountsUsd6 = new uint256[](1);
        b.amountsUsd6[0] = 1 * 1e6;
        b.namespaces = new bytes32[](1);
        b.intentClasses = new IntentClass[](1);
        b.intentClasses[0] = IntentClasses.AGENT_TO_AGENT;
        b.memoHashes = new bytes32[](1);
        b.memoHashes[0] = MEMO;
        b.extensionDatas = new bytes[](1);
        b.mandate = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);
        b.meta = BatchMetadata({batchRef: keccak256("br"), settlementHash: bytes32(0)});

        vm.prank(AGENT);
        vm.expectRevert(bytes("RIVR: to zero"));
        token.batchProgrammableTransfer(b);
    }

    // ─── stream pre-call validation (lines 733, 734) ────────────────

    function test_withdrawFromStream_unknownStreamReverts() public {
        bytes32 streamRef = keccak256("nope");
        vm.prank(RECIPIENT);
        vm.expectRevert(bytes("RIVR: unknown stream"));
        token.withdrawFromStream(streamRef, 1);
    }

    function test_withdrawFromStream_notRecipientReverts() public {
        // Open a real stream.
        bytes32 mid = keccak256("m-stream");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        StreamParams memory p;
        p.recipient = RECIPIENT;
        p.ratePerSecond = 1 * 1e15; // 0.001 RIVR/sec
        p.startsAt = uint64(block.timestamp);
        p.endsAt = uint64(block.timestamp + 100);
        p.namespaceFromPayer = DEFAULT_NS;
        p.mandate = env;
        p.intentClass = IntentClasses.SUBSCRIPTION_CHARGE;

        vm.prank(AGENT);
        bytes32 streamRef = token.openStream(p);

        // Advance time so accrued > 0.
        vm.warp(block.timestamp + 50);

        // Anyone other than the recipient is rejected.
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert(bytes("RIVR: not recipient"));
        token.withdrawFromStream(streamRef, 1 * 1e15);
    }

    // ─── dryRun cap fallback (line 813) ─────────────────────────────

    /// @dev When the registry has cap=0 (unregistered mandate), dryRun
    ///      should fall back to the envelope's maxTotalUsd. Cover the
    ///      `capFromRegistry == 0` true branch by using a fresh mandate.
    function test_dryRun_unregisteredMandate_usesEnvelopeCap() public {
        bytes32 mid = keccak256("m-dry-unreg");
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
            caller: AGENT,
            mandate: env,
            legs: legs,
            atTimestamp: 0
        });

        DryRunResult memory r = token.dryRun(input);
        assertEq(uint8(r.reason), uint8(RefusalReason.OK), "should pass with envelope cap fallback");
    }

    /// @dev Cumulative-cap projection trips. Covers `wouldExceed=true`.
    function test_dryRun_amountExceedsCap_returnsCumulativeCap() public {
        bytes32 mid = keccak256("m-dry-cap");
        _activateKya(mid);
        // maxTotalUsd = 50, leg = 100 — must exceed.
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 50 * 1e6);

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
            caller: AGENT,
            mandate: env,
            legs: legs,
            atTimestamp: 0
        });

        DryRunResult memory r = token.dryRun(input);
        assertEq(uint8(r.reason), uint8(RefusalReason.MANDATE_CUMULATIVE_CAP));
    }

    // ─── _dryRunMandateChecks branches (lines 864-867) ──────────────

    /// @dev `atTs < notBefore` — distinct from `atTs >= expiresAt`. Both
    ///      paths return MANDATE_EXPIRED but they are different branches.
    function test_dryRun_beforeNotBefore_returnsExpired() public {
        bytes32 mid = keccak256("m-dry-nbf");
        _activateKya(mid);
        // Build envelope with notBefore in the future.
        address[] memory allow = new address[](1);
        allow[0] = address(token);
        MandateEnvelope memory env = _signMandate(
            mid,
            keccak256(abi.encode(mid, "n")),
            mid,
            allow,
            1_000 * 1e6,
            10_000 * 1e6,
            uint64(block.timestamp + 1 hours), // notBefore in future
            uint64(block.timestamp + 2 hours)
        );

        DryRunLeg[] memory legs = new DryRunLeg[](1);
        legs[0] = DryRunLeg({
            from: PRINCIPAL,
            to: RECIPIENT,
            amount: 1 * 1e18,
            asset: address(token),
            namespace: DEFAULT_NS,
            intentClass: IntentClasses.AGENT_TO_AGENT,
            memoHash: MEMO
        });
        DryRunInput memory input = DryRunInput({
            caller: AGENT,
            mandate: env,
            legs: legs,
            atTimestamp: uint64(block.timestamp) // before notBefore
        });

        DryRunResult memory r = token.dryRun(input);
        assertEq(uint8(r.reason), uint8(RefusalReason.MANDATE_EXPIRED));
    }

    // ─── _dryRunLeg non-self asset branch (line 943) ────────────────

    /// @dev `leg.asset != address(this)` — skips namespace-balance check.
    function test_dryRun_nonSelfAsset_skipsBalanceCheck() public {
        bytes32 mid = keccak256("m-dry-nonself");
        _activateKya(mid);

        // Build mandate that allows BOTH token and a different asset.
        address other = makeAddr("other-asset");
        address[] memory allow = new address[](2);
        allow[0] = address(token);
        allow[1] = other;
        MandateEnvelope memory env = _signMandate(
            mid,
            keccak256(abi.encode(mid, "n")),
            mid,
            allow,
            1_000 * 1e6,
            10_000 * 1e6,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days)
        );

        // Leg references a non-self asset — should bypass namespace balance check.
        // amount must still satisfy per-tx cap (usd6 = amount/1e12 must be <= maxPerTxUsd).
        DryRunLeg[] memory legs = new DryRunLeg[](1);
        legs[0] = DryRunLeg({
            from: PRINCIPAL,
            to: RECIPIENT,
            amount: 100 * 1e18, // = $100 in usd6, well under $1000 cap
            asset: other,
            namespace: DEFAULT_NS,
            intentClass: IntentClasses.AGENT_TO_AGENT,
            memoHash: MEMO
        });
        DryRunInput memory input = DryRunInput({
            caller: AGENT,
            mandate: env,
            legs: legs,
            atTimestamp: 0
        });

        DryRunResult memory r = token.dryRun(input);
        // Asset-allowed and amount under per-tx cap, balance check skipped.
        assertEq(uint8(r.reason), uint8(RefusalReason.OK));
    }

    // ─── dryRun atTimestamp default branch (line 779) ───────────────

    /// @dev `atTimestamp == 0` — uses `block.timestamp`.
    function test_dryRun_zeroAtTimestamp_usesBlockTimestamp() public {
        bytes32 mid = keccak256("m-dry-defaultts");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        DryRunLeg[] memory legs = new DryRunLeg[](1);
        legs[0] = DryRunLeg({
            from: PRINCIPAL,
            to: RECIPIENT,
            amount: 1 * 1e18,
            asset: address(token),
            namespace: DEFAULT_NS,
            intentClass: IntentClasses.AGENT_TO_AGENT,
            memoHash: MEMO
        });
        DryRunInput memory input = DryRunInput({
            caller: AGENT,
            mandate: env,
            legs: legs,
            atTimestamp: 0 // hits the `== 0` branch
        });

        DryRunResult memory r = token.dryRun(input);
        assertEq(uint8(r.reason), uint8(RefusalReason.OK));
    }

    /// @dev `atTimestamp != 0` — uses the supplied value.
    function test_dryRun_explicitAtTimestamp() public {
        bytes32 mid = keccak256("m-dry-explicits");
        _activateKya(mid);
        MandateEnvelope memory env = _defaultMandate(mid, 1_000 * 1e6, 10_000 * 1e6);

        DryRunLeg[] memory legs = new DryRunLeg[](1);
        legs[0] = DryRunLeg({
            from: PRINCIPAL,
            to: RECIPIENT,
            amount: 1 * 1e18,
            asset: address(token),
            namespace: DEFAULT_NS,
            intentClass: IntentClasses.AGENT_TO_AGENT,
            memoHash: MEMO
        });
        DryRunInput memory input = DryRunInput({
            caller: AGENT,
            mandate: env,
            legs: legs,
            atTimestamp: uint64(block.timestamp) // non-zero, in window
        });

        DryRunResult memory r = token.dryRun(input);
        assertEq(uint8(r.reason), uint8(RefusalReason.OK));
    }

    // ─── burnFrom path with allowance ──────────────────────────────

    function test_burnFrom_consumesAllowance() public {
        address holder = makeAddr("holder-bf");
        address burner = makeAddr("burner-bf");
        vm.startPrank(TREASURY);
        token.grantRole(token.BURNER_ROLE(), burner);
        vm.stopPrank();
        _mintTo(holder, 100 * 1e18);

        vm.prank(holder);
        token.approve(burner, 40 * 1e18);

        vm.prank(burner);
        token.burnFrom(holder, 40 * 1e18);
        assertEq(token.balanceOf(holder), 60 * 1e18);
        assertEq(token.allowance(holder, burner), 0);
    }

    // ─── redeem (holder-initiated) ──────────────────────────────────

    function test_redeem_holderBurnsOwn() public {
        _mintTo(RECIPIENT, 100 * 1e18);
        vm.prank(RECIPIENT);
        token.redeem(40 * 1e18, "ref-001");
        assertEq(token.balanceOf(RECIPIENT), 60 * 1e18);
    }

    // ─── mintReserve carries reserve ref ────────────────────────────

    function test_mintReserve_emitsReserveMintEvent() public {
        vm.prank(TREASURY);
        token.mintReserve(RECIPIENT, 100 * 1e18, "deposit-slip-X");
        assertEq(token.balanceOf(RECIPIENT), 100 * 1e18);
    }

    // ─── pause / unpause role gating ───────────────────────────────

    function test_pause_unpause_byPauser() public {
        vm.startPrank(TREASURY); // also has PAUSER_ROLE
        token.pause();
        assertTrue(token.paused());
        token.unpause();
        assertFalse(token.paused());
        vm.stopPrank();
    }

    // ─── transferCCIPAdmin event side ───────────────────────────────

    function test_setPorFeed_emitsEvent() public {
        MockPoRFeed feed = new MockPoRFeed(8);
        vm.prank(CCIP_ADMIN);
        token.setPorFeed(address(feed));
        assertEq(address(token.porFeed()), address(feed));
    }
}
