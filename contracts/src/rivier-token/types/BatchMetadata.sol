// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title BatchMetadata
 * @notice Metadata for a programmable batch transfer.
 *
 * Each batch has a single authorizing MandateEnvelope that bounds the sum of all legs.
 * `batchRef` and `settlementHash` let off-chain systems correlate the on-chain batch
 * with whatever queueing/settlement record it came from (rivier-batch coordinator,
 * Canton DVP, off-chain scheduler).
 *
 * Per design doc §3 ProgrammableTransferEvent, every leg of a batch emits its own
 * event with `transferRef = batchRef ^ legIndex` so consumers can reconstruct the
 * full batch from on-chain logs alone.
 */
struct BatchMetadata {
    /// @dev Caller-supplied unique batch identifier (e.g. rivier-batch UUID hashed).
    bytes32 batchRef;

    /// @dev Optional off-chain settlement hash (Canton DVP commit hash, etc.).
    ///      Zero when the batch isn't bound to an external settlement record.
    bytes32 settlementHash;
}
