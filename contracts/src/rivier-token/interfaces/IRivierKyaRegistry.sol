// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IRivierKyaRegistry
 * @notice On-chain mirror of W3C VCs issued by did:web:identity.rivier.ai.
 *
 * KYA is dual-source per CLAUDE.md §"KYA — dual source of truth":
 *   - The W3C VC at did:web:identity.rivier.ai is canonical for credentialing
 *     (third-party verifiers fetch this).
 *   - This registry is canonical for transfer authorization (the token contract
 *     trusts only what's here).
 *
 * `KyaSyncWorker` in rivier-identity keeps them aligned — target ≤60s P95 lag.
 *
 * The token contract calls `isValid(credentialHash)` on every transferWithMandate.
 * If the credential isn't valid (unknown / expired / revoked / stale), the token
 * reverts with a typed RefusalReason without consulting the policy hook.
 */
interface IRivierKyaRegistry {
    /// @dev Emitted when a credential is upserted by the sync worker.
    event KyaCredentialUpdated(
        bytes32 indexed credentialHash,
        address indexed issuer,
        uint64 expiresAt,
        uint64 syncedAt
    );

    /// @dev Emitted when a credential is explicitly revoked.
    event KyaCredentialRevoked(bytes32 indexed credentialHash, address indexed by, uint64 at);

    /// @dev Status of a credential in the registry.
    enum KyaStatus {
        UNKNOWN,    // 0 — never synced (default for unknown hashes)
        ACTIVE,     // 1 — current
        EXPIRED,    // 2 — past expiresAt
        REVOKED     // 3 — explicitly revoked
    }

    struct KyaRecord {
        address issuer;          // expected: did:web:identity.rivier.ai issuer key
        KyaStatus status;
        uint64 expiresAt;        // unix seconds
        uint64 lastSyncedAt;     // unix seconds
    }

    /**
     * @notice Sync wallet upserts a credential record. ROLE-gated to KYA_SYNC_ROLE.
     */
    function upsertCredential(
        bytes32 credentialHash,
        address issuer,
        uint64 expiresAt
    ) external;

    /**
     * @notice Sync wallet (or recovery role) explicitly revokes a credential.
     *         ROLE-gated to KYA_SYNC_ROLE.
     */
    function revokeCredential(bytes32 credentialHash) external;

    /**
     * @notice Returns the full record for a credential. Status==UNKNOWN if absent.
     */
    function recordOf(bytes32 credentialHash) external view returns (KyaRecord memory);

    /**
     * @notice Returns true iff the credential is ACTIVE and not past expiry.
     *         Used by the token's transferWithMandate as the inline KYA gate.
     */
    function isValid(bytes32 credentialHash) external view returns (bool);

    /**
     * @notice Seconds since the registry last saw an update for this credential.
     *         Returns type(uint64).max if the credential is unknown.
     */
    function staleness(bytes32 credentialHash) external view returns (uint64);
}
