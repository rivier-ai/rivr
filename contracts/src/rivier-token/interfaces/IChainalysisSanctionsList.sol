// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IChainalysisSanctionsList
 * @notice Read-only oracle interface for the deployed Chainalysis
 *         sanctions list at `0x40C57923924B5c5c5455c48D93317139ADDaC8fb`
 *         on Ethereum / Optimism / Polygon / Arbitrum / Avalanche.
 *
 * The PolicyHook consults this oracle inline. If the deployed address
 * is `address(0)` (a chain Chainalysis hasn't shipped to yet, e.g.
 * Base at certain points), the hook short-circuits to "not sanctioned"
 * and surfaces the gap via an admin-readable flag — sanctions screening
 * is then enforced off-chain at the API gateway / KYA issuance layer
 * until Chainalysis publishes the lane.
 *
 * `setSanctionsOracle` on the hook is timelocked so a future deploy
 * can swap in the real address without a contract upgrade.
 */
interface IChainalysisSanctionsList {
    /// @notice True iff `addr` is on the Chainalysis sanctioned addresses list.
    function isSanctioned(address addr) external view returns (bool);
}
