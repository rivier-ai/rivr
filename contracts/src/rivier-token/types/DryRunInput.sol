// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MandateEnvelope} from "./MandateEnvelope.sol";
import {IntentClass} from "./IntentClass.sol";

/**
 * @title DryRunInput
 * @notice Input legs for the token's `dryRun(input)` view simulator.
 *
 * `dryRun` walks the same policy chain as `transferWithMandate` /
 * `batchProgrammableTransfer` but as a state-read-only simulation. Used by agents
 * before committing a real transfer so they can branch on the typed RefusalReason
 * without paying gas or burning a nonce.
 *
 * The byte-equivalence invariant: for any (caller, mandate, leg) tuple,
 * `dryRun({legs:[leg], mandate, caller}).reason` MUST equal the `RefusalReason`
 * a real `transferWithMandate(...)` would revert with (or `OK` if it would succeed).
 * The test suite enforces this invariant.
 *
 * Single-leg dry-runs simulate `transferWithMandate`. Multi-leg dry-runs simulate
 * `batchProgrammableTransfer` and project cumulative-cap checks against the sum.
 */
struct DryRunLeg {
    address from;
    address to;
    uint256 amount;
    address asset;          // token contract address (this contract for RIVR)
    bytes32 namespace;      // payer namespace; zero = DEFAULT_NS
    IntentClass intentClass;
    bytes32 memoHash;
}

struct DryRunInput {
    DryRunLeg[] legs;
    MandateEnvelope mandate;
    address caller;         // the address that would call transferWithMandate
                            // (typically the agent address)
    uint64 atTimestamp;     // unix seconds the simulation should treat as "now".
                            // Zero means use block.timestamp.
}
