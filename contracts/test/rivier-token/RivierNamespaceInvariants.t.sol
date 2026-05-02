// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RivierTestBase} from "./Base.t.sol";

/// @notice Invariant tests for the sub-balance namespace book-keeping.
///
/// Load-bearing invariants:
///   I1) `balanceOf(holder) == sum_{ns} balanceOfNamespace(holder, ns)`.
///       The aggregate accessor MUST equal the per-namespace sum at all
///       times, otherwise downstream consumers (block explorers, the
///       wallet UI, accounting tools) read an inconsistent picture.
///   I2) `transferNamespace(fromNs, toNs, amount)` is sum-preserving on
///       the holder — total balance unchanged before vs. after.
///   I3) Namespace-bounded debits don't spill into other namespaces — a
///       transfer originating from `nsA` MUST decrement only `nsA` and
///       not touch `DEFAULT_NS` or any other namespace.
///   I4) `deposit` / `withdrawFromNamespace` are sum-preserving on the
///       caller (move funds between caller's own namespaces).
///
/// Fuzz tests use a small holder set so the assertions remain provable
/// per-run; the property holds for any holder regardless.
contract RivierNamespaceInvariantsTest is RivierTestBase {
    bytes32 internal constant NS_A = keccak256("ns-a");
    bytes32 internal constant NS_B = keccak256("ns-b");
    bytes32 internal constant NS_C = keccak256("ns-c");

    function setUp() public override {
        super.setUp();
        // Mint 1M RIVR to the principal so the harness has float to move.
        _mintTo(PRINCIPAL, 1_000_000 * 1e18);
    }

    function _sumNamespaces(address holder) internal view returns (uint256 sum) {
        bytes32[] memory list = token.namespacesOf(holder);
        for (uint256 i = 0; i < list.length; ++i) {
            sum += token.balanceOfNamespace(holder, list[i]);
        }
    }

    // ─── I1: balanceOf == sum(balanceOfNamespace) ───────────────────

    function test_balanceOfEqualsSum_afterMint() public view {
        assertEq(token.balanceOf(PRINCIPAL), _sumNamespaces(PRINCIPAL));
    }

    function test_balanceOfEqualsSum_afterDeposit() public {
        vm.prank(PRINCIPAL);
        token.deposit(NS_A, 100 * 1e18);
        assertEq(token.balanceOf(PRINCIPAL), _sumNamespaces(PRINCIPAL));
    }

    function test_balanceOfEqualsSum_afterMultipleNamespaces() public {
        vm.startPrank(PRINCIPAL);
        token.deposit(NS_A, 100 * 1e18);
        token.deposit(NS_B, 200 * 1e18);
        token.deposit(NS_C, 50 * 1e18);
        vm.stopPrank();
        assertEq(token.balanceOf(PRINCIPAL), _sumNamespaces(PRINCIPAL));
    }

    function testFuzz_balanceOfEqualsSum_afterRandomDeposits(
        uint128 a,
        uint128 b,
        uint128 c
    ) public {
        // Cap each value so we don't overflow PRINCIPAL's float.
        uint256 ax = uint256(a) % (300_000 * 1e18);
        uint256 bx = uint256(b) % (300_000 * 1e18);
        uint256 cx = uint256(c) % (300_000 * 1e18);
        vm.startPrank(PRINCIPAL);
        if (ax > 0) token.deposit(NS_A, ax);
        if (bx > 0) token.deposit(NS_B, bx);
        if (cx > 0) token.deposit(NS_C, cx);
        vm.stopPrank();
        assertEq(token.balanceOf(PRINCIPAL), _sumNamespaces(PRINCIPAL));
    }

    // ─── I2: transferNamespace is sum-preserving ────────────────────

    function test_transferNamespace_isSumPreserving() public {
        uint256 totalBefore = token.balanceOf(PRINCIPAL);
        vm.startPrank(PRINCIPAL);
        token.deposit(NS_A, 500 * 1e18);
        token.transferNamespace(NS_A, NS_B, 200 * 1e18);
        vm.stopPrank();
        assertEq(token.balanceOf(PRINCIPAL), totalBefore);
        assertEq(_sumNamespaces(PRINCIPAL), totalBefore);
    }

    function testFuzz_transferNamespace_isSumPreserving(uint128 amount) public {
        // Seed NS_A with 1000 RIVR.
        uint256 seed = 1000 * 1e18;
        vm.startPrank(PRINCIPAL);
        token.deposit(NS_A, seed);
        uint256 totalBefore = token.balanceOf(PRINCIPAL);
        uint256 moveAmount = uint256(amount) % seed;
        if (moveAmount > 0) {
            token.transferNamespace(NS_A, NS_B, moveAmount);
        }
        vm.stopPrank();
        assertEq(token.balanceOf(PRINCIPAL), totalBefore);
        assertEq(_sumNamespaces(PRINCIPAL), totalBefore);
    }

    // ─── I3: namespace-bounded debits stay in their lane ────────────

    function test_namespaceBoundedDebit_doesNotTouchOtherNamespaces() public {
        vm.startPrank(PRINCIPAL);
        token.deposit(NS_A, 100 * 1e18);
        token.deposit(NS_B, 200 * 1e18);
        uint256 defaultBefore = token.balanceOfNamespace(PRINCIPAL, DEFAULT_NS);
        uint256 nsBBefore = token.balanceOfNamespace(PRINCIPAL, NS_B);

        // Move from NS_A to NS_C — must not affect DEFAULT or NS_B.
        token.transferNamespace(NS_A, NS_C, 50 * 1e18);
        vm.stopPrank();

        assertEq(token.balanceOfNamespace(PRINCIPAL, DEFAULT_NS), defaultBefore);
        assertEq(token.balanceOfNamespace(PRINCIPAL, NS_B), nsBBefore);
        assertEq(token.balanceOfNamespace(PRINCIPAL, NS_A), 50 * 1e18);
        assertEq(token.balanceOfNamespace(PRINCIPAL, NS_C), 50 * 1e18);
    }

    // ─── I4: deposit + withdrawFromNamespace are sum-preserving ─────

    function test_depositWithdraw_isSumPreserving() public {
        uint256 totalBefore = token.balanceOf(PRINCIPAL);
        vm.startPrank(PRINCIPAL);
        token.deposit(NS_A, 300 * 1e18);
        token.withdrawFromNamespace(NS_A, PRINCIPAL, 300 * 1e18);
        vm.stopPrank();
        // After deposit-then-withdraw to self, sums must reconcile.
        assertEq(token.balanceOf(PRINCIPAL), totalBefore);
    }

    function test_withdrawFromNamespace_creditsRecipientDefault() public {
        address bob = makeAddr("bob");
        vm.startPrank(PRINCIPAL);
        token.deposit(NS_A, 100 * 1e18);
        token.withdrawFromNamespace(NS_A, bob, 60 * 1e18);
        vm.stopPrank();
        assertEq(token.balanceOfNamespace(bob, DEFAULT_NS), 60 * 1e18);
        assertEq(token.balanceOfNamespace(PRINCIPAL, NS_A), 40 * 1e18);
    }

    // ─── namespacesOf enumeration is push-only and dedup'd ──────────

    function test_namespacesOf_doesNotDuplicateOnRepeatedDeposit() public {
        vm.startPrank(PRINCIPAL);
        token.deposit(NS_A, 100 * 1e18);
        token.deposit(NS_A, 200 * 1e18); // second deposit to same NS
        vm.stopPrank();
        bytes32[] memory list = token.namespacesOf(PRINCIPAL);
        uint256 nsACount;
        for (uint256 i = 0; i < list.length; ++i) {
            if (list[i] == NS_A) nsACount++;
        }
        assertEq(nsACount, 1, "NS_A should appear exactly once");
    }
}
