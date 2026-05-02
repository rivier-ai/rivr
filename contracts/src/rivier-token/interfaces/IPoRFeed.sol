// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IPoRFeed
 * @notice Minimal AggregatorV3-shaped interface used by RIVR's PoR (Proof
 * of Reserve) gate. Chainlink's PoR feeds expose the standard
 * AggregatorV3Interface; we only need a subset to enforce the mint guard.
 *
 * Why we don't import the full AggregatorV3Interface:
 *   - Keeps the contracts/ tree self-contained (no chainlink package lock-in
 *     for what is otherwise a clean ERC-20 + AccessControl).
 *   - Makes the test surface trivial — a mock implementing 3 methods.
 *
 * Mainnet wires `setPorFeed(<chainlink_por_address>)` after PoR launch;
 * testnet leaves the feed unset and the guard is short-circuited (see
 * RivierTokenCCT.mint() for the bypass condition).
 */
interface IPoRFeed {
    function decimals() external view returns (uint8);
    function latestAnswer() external view returns (int256);
    function latestTimestamp() external view returns (uint256);
}
