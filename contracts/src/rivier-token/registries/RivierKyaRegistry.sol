// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IRivierKyaRegistry} from "../interfaces/IRivierKyaRegistry.sol";

/**
 * @title RivierKyaRegistry
 * @notice On-chain mirror of W3C VCs issued by `did:web:identity.rivier.ai`.
 *
 * MIT-licensed. Architectural reference: ERC-3643 IdentityRegistry (GPL —
 * not vendored, re-implemented here).
 *
 * The KyaSyncWorker in rivier-identity holds `KYA_SYNC_ROLE` (multi-sig
 * sync wallet) and is responsible for keeping the on-chain mirror within
 * 60 seconds P95 of the canonical VC at did:web:identity.rivier.ai.
 *
 * Token-side authority: the RIVR token contract calls `isValid` inline on
 * every `transferWithMandate`. Status decisions:
 *   - UNKNOWN  → invalid (the credential was never synced)
 *   - ACTIVE   → valid IFF `block.timestamp <= expiresAt`
 *   - EXPIRED  → invalid
 *   - REVOKED  → invalid
 *
 * Lazy expiry: a credential whose `expiresAt` is past will return invalid
 * even while its stored status is still `ACTIVE`. The sync worker MAY
 * later upsert the same credentialHash with `EXPIRED` status to make the
 * timeline clean, but the on-chain check does not depend on it.
 */
contract RivierKyaRegistry is IRivierKyaRegistry, AccessControl {
    bytes32 public constant KYA_SYNC_ROLE = keccak256("KYA_SYNC_ROLE");

    mapping(bytes32 credentialHash => KyaRecord) private _records;

    /// @notice Reverts when `revokeCredential` is invoked against a
    ///         credentialHash that was never recorded.
    error UnknownCredential(bytes32 credentialHash);

    /// @notice Deploy the registry with an admin and the initial sync wallet.
    /// @param admin       DEFAULT_ADMIN_ROLE recipient. MUST NOT be zero.
    /// @param syncWallet  Initial KYA_SYNC_ROLE holder — the rivier-identity
    ///                    multi-sig that mirrors W3C VCs from
    ///                    did:web:identity.rivier.ai. MUST NOT be zero.
    constructor(address admin, address syncWallet) {
        require(admin != address(0), "RIVR-KYA: admin zero");
        require(syncWallet != address(0), "RIVR-KYA: sync zero");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KYA_SYNC_ROLE, syncWallet);
    }

    /// @inheritdoc IRivierKyaRegistry
    function upsertCredential(
        bytes32 credentialHash,
        address issuer,
        uint64 expiresAt
    ) external onlyRole(KYA_SYNC_ROLE) {
        require(credentialHash != bytes32(0), "RIVR-KYA: hash zero");
        require(issuer != address(0), "RIVR-KYA: issuer zero");
        require(expiresAt > block.timestamp, "RIVR-KYA: already expired");

        uint64 nowSec = uint64(block.timestamp);
        _records[credentialHash] = KyaRecord({
            issuer: issuer,
            status: KyaStatus.ACTIVE,
            expiresAt: expiresAt,
            lastSyncedAt: nowSec
        });

        emit KyaCredentialUpdated(credentialHash, issuer, expiresAt, nowSec);
    }

    /// @inheritdoc IRivierKyaRegistry
    function revokeCredential(bytes32 credentialHash)
        external
        onlyRole(KYA_SYNC_ROLE)
    {
        KyaRecord storage rec = _records[credentialHash];
        if (rec.issuer == address(0)) revert UnknownCredential(credentialHash);

        rec.status = KyaStatus.REVOKED;
        rec.lastSyncedAt = uint64(block.timestamp);

        emit KyaCredentialRevoked(credentialHash, msg.sender, uint64(block.timestamp));
    }

    /// @inheritdoc IRivierKyaRegistry
    function recordOf(bytes32 credentialHash)
        external
        view
        returns (KyaRecord memory)
    {
        return _records[credentialHash];
    }

    /// @inheritdoc IRivierKyaRegistry
    function isValid(bytes32 credentialHash) external view returns (bool) {
        KyaRecord storage rec = _records[credentialHash];
        if (rec.status != KyaStatus.ACTIVE) return false;
        if (rec.expiresAt <= block.timestamp) return false;
        return true;
    }

    /// @inheritdoc IRivierKyaRegistry
    function staleness(bytes32 credentialHash) external view returns (uint64) {
        KyaRecord storage rec = _records[credentialHash];
        if (rec.issuer == address(0)) return type(uint64).max;
        uint64 nowSec = uint64(block.timestamp);
        if (rec.lastSyncedAt >= nowSec) return 0;
        return nowSec - rec.lastSyncedAt;
    }
}
