// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IRivierMandateRegistry
 * @notice Tracks per-mandate cumulative spend and explicit revocations.
 *
 * Architectural reference: Safe AllowanceModule (LGPL — re-implemented MIT here).
 *
 * Cumulative spend is the load-bearing constraint: a mandate's `maxTotalUsd` cap
 * means nothing without persistent state tracking what's been spent. The token
 * contract calls `recordMandateUse(id, amountUsd)` after every transferWithMandate
 * succeeds (CEI: state writes happen AFTER the transfer balance update commits).
 *
 * Revocation paths:
 *   - `revokeMandate(id)` — only the principal can revoke their own mandate.
 *   - `revokeAllMandates(principal)` — RECOVERY_ROLE-gated (a separate recovery key
 *     held by the principal's recovery share). Used after a device compromise.
 */
interface IRivierMandateRegistry {
    /// @dev Emitted on every successful spend record.
    event MandateUsed(
        bytes32 indexed mandateId,
        address indexed principal,
        address indexed agent,
        uint256 amountUsd,
        uint256 cumulativeUsd
    );

    /// @dev Emitted when a principal revokes one of their mandates.
    event MandateRevoked(bytes32 indexed mandateId, address indexed principal, uint64 at);

    /// @dev Emitted when recovery role mass-revokes all mandates for a principal.
    event AllMandatesRevoked(address indexed principal, address indexed by, uint64 at);

    struct MandateRecord {
        address principal;
        address agent;
        bytes32 kyaCredentialHash;
        uint256 maxTotalUsd;
        uint64 expiresAt;
        uint256 cumulativeSpentUsd;
        bool revoked;
    }

    /**
     * @notice Record a use of `mandateId` for `amountUsd` (6-decimal USD).
     *         Also lazily registers the mandate's metadata on first use.
     *         ROLE-gated to TOKEN_ROLE (the RIVR token contract).
     *
     *         Reverts if the mandate is already revoked or if the cumulative
     *         total would exceed `maxTotalUsd`. The token treats both as
     *         hard refusals and surfaces the typed RefusalReason.
     *
     * @param mandateId           the bytes32 id from MandateEnvelope.mandateId
     * @param principal           recorded on first registration
     * @param agent               recorded on first registration
     * @param kyaCredentialHash   recorded on first registration
     * @param maxTotalUsd         recorded on first registration (cap)
     * @param expiresAt           recorded on first registration (unix seconds)
     * @param amountUsd           amount to charge against the cumulative cap
     */
    function recordMandateUse(
        bytes32 mandateId,
        address principal,
        address agent,
        bytes32 kyaCredentialHash,
        uint256 maxTotalUsd,
        uint64 expiresAt,
        uint256 amountUsd
    ) external;

    /**
     * @notice Principal-only revocation. msg.sender must equal the registered
     *         principal of `mandateId`.
     */
    function revokeMandate(bytes32 mandateId) external;

    /**
     * @notice Mass revocation across every mandate registered for `principal`.
     *         RECOVERY_ROLE-gated. Intended for post-compromise sweeps.
     */
    function revokeAllMandates(address principal) external;

    /// @notice Cumulative USD spent against this mandate (6-decimal).
    function cumulativeSpend(bytes32 mandateId) external view returns (uint256);

    /// @notice Full mandate record. Zero-valued if unknown.
    function recordOf(bytes32 mandateId) external view returns (MandateRecord memory);

    /// @notice True iff the mandate has been revoked OR is past expiry.
    function isRevokedOrExpired(bytes32 mandateId) external view returns (bool);

    /**
     * @notice Project the cumulative spend if `additionalUsd` were applied to
     *         `mandateId`. Used by `dryRun` to test the cap without writing.
     *         Returns the projected total even if it exceeds the cap; the
     *         caller compares against `recordOf(mandateId).maxTotalUsd`.
     */
    function projectCumulative(bytes32 mandateId, uint256 additionalUsd)
        external
        view
        returns (uint256 projectedTotal, uint256 cap, bool wouldExceed);
}
