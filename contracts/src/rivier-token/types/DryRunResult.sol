// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RefusalReason} from "./RefusalReason.sol";

/**
 * @title DryRunResult
 * @notice Structured outcome from `dryRun(input)`.
 *
 * `reason == OK` means the simulation projects success. Any other value is the
 * exact `RefusalReason` a real `transferWithMandate` / `batchProgrammableTransfer`
 * would revert with.
 *
 * `ctx` mirrors the `ctx` field on `RivierRefused` — same producer-defined
 * 32-byte tag.
 *
 * `projectedCumulativeUsd` is the post-transfer cumulative spend that would be
 * recorded against `mandate.mandateId` if the legs went through. Off-chain agents
 * use this for budget projection over multiple proposed legs.
 *
 * `legResults` provides per-leg outcomes for batch dry-runs. For single-leg
 * dry-runs it has length 1 with the same reason as the top-level field.
 */
struct DryRunLegResult {
    RefusalReason reason;
    bytes32 ctx;
}

struct DryRunResult {
    RefusalReason reason;
    bytes32 ctx;
    uint256 projectedCumulativeUsd;
    DryRunLegResult[] legResults;
}
