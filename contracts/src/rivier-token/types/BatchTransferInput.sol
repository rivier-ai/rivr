// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IntentClass} from "./IntentClass.sol";
import {MandateEnvelope} from "./MandateEnvelope.sol";
import {BatchMetadata} from "./BatchMetadata.sol";

/**
 * @title BatchTransferInput
 * @notice Bundle of all calldata required for `batchProgrammableTransfer`.
 *
 * The launch surface specifies a per-leg array shape (recipients, amounts,
 * amountsUsd6, namespaces, intentClasses, memoHashes, extensionDatas) plus
 * a single authorizing MandateEnvelope and BatchMetadata. Solidity's local
 * variable budget cannot accommodate that many calldata array references in
 * one function frame even with `via_ir = true` (Yul stack-too-deep on the
 * outer entry). Bundling them into a single calldata struct collapses the
 * frame to a single calldata pointer.
 *
 * All arrays MUST be the same length (`recipients.length`); the token
 * contract enforces this at the entry. Array invariants per leg `i`:
 *   - `recipients[i] != address(0)`
 *   - `amountsUsd6[i]` is the USD-decimals (6) projection of `amounts[i]`
 *     for the cumulative-spend tracker on the mandate registry. RIVR is
 *     1:1 USD so `amountsUsd6[i] = amounts[i] / 1e12` (RIVR has 18
 *     decimals, USD-tracker has 6). Caller is responsible for the scale.
 *   - `namespaces[i]` is the source namespace on the principal's account
 *     (use `bytes32(0)` for DEFAULT_NS).
 *   - `intentClasses[i]` is the IntentClass for that leg (per-leg, not
 *     per-batch — batches CAN mix intent classes).
 *   - `memoHashes[i]` is the per-leg memo hash; surfaces in the leg's
 *     emitted ProgrammableTransferEvent.
 *   - `extensionDatas[i]` is the per-leg v1 extension blob (agent
 *     attestation, etc.). Length-zero is allowed for non-agent legs.
 */
struct BatchTransferInput {
    address[] recipients;
    uint256[] amounts;
    uint256[] amountsUsd6;
    bytes32[] namespaces;
    IntentClass[] intentClasses;
    bytes32[] memoHashes;
    bytes[] extensionDatas;
    MandateEnvelope mandate;
    BatchMetadata meta;
}
