// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IRivierMandateRegistry} from "../interfaces/IRivierMandateRegistry.sol";

/**
 * @title RivierMandateRegistry
 * @notice Tracks per-mandate cumulative spend and explicit revocations.
 *
 * MIT-licensed. Architectural reference: Safe AllowanceModule (LGPL —
 * not vendored, re-implemented here).
 *
 * Two roles besides the default admin:
 *   - TOKEN_ROLE     — granted to the RIVR token contract. Authorises
 *                      `recordMandateUse`, the only state-mutating path
 *                      that increments cumulative spend.
 *   - RECOVERY_ROLE  — granted to the principal's recovery share/key.
 *                      Authorises mass-revocation across every mandate
 *                      registered for a given principal. Used after a
 *                      device compromise.
 *
 * State model: a mandate is "lazily registered" on first `recordMandateUse`
 * — the token is the only caller, and it has already verified the
 * principal's EIP-712 signature on the envelope. The metadata recorded
 * here (principal, agent, kyaCredentialHash, maxTotalUsd, expiresAt)
 * is the binding image of that verified envelope; subsequent uses
 * reference the same `mandateId` and only increment cumulativeSpentUsd.
 *
 * Reentrancy: the registry only exposes external state-mutating paths
 * to TOKEN_ROLE / principal / RECOVERY_ROLE. The token follows CEI —
 * it updates balances FIRST, then calls `recordMandateUse`. No native
 * value moves through this contract, so no reentrancy guards are
 * required.
 *
 * Tracking principal→mandates mapping for `revokeAllMandates`: the
 * registry maintains `_mandatesByPrincipal[principal]` as a push-only
 * array of `mandateId`s seen for that principal. Revocations are
 * iterative; gas-bounded by the number of mandates a single principal
 * has lifetime-registered. In practice this is a small set (one per
 * agent the principal has authorised). No deletions from the array —
 * a revoked mandate stays in the list and is short-circuited by the
 * `revoked` flag in its record.
 */
contract RivierMandateRegistry is IRivierMandateRegistry, AccessControl {
    bytes32 public constant TOKEN_ROLE = keccak256("TOKEN_ROLE");
    bytes32 public constant RECOVERY_ROLE = keccak256("RECOVERY_ROLE");

    mapping(bytes32 mandateId => MandateRecord) private _records;
    mapping(address principal => bytes32[]) private _mandatesByPrincipal;

    /// @notice Reverts when a caller asks about a mandate that was never recorded.
    error UnknownMandate(bytes32 mandateId);
    /// @notice Reverts when `revokeMandate` is invoked by anyone other than the
    ///         registered principal of `mandateId`.
    error NotPrincipal(bytes32 mandateId, address caller, address expected);
    /// @notice Reverts when `recordMandateUse` or `revokeMandate` is invoked
    ///         against a mandate already in the revoked state.
    error MandateAlreadyRevoked(bytes32 mandateId);
    /// @notice Reverts when a recorded use would push cumulative spend past
    ///         the per-mandate `maxTotalUsd` cap.
    error CumulativeCapExceeded(bytes32 mandateId, uint256 attempted, uint256 cap);
    /// @notice Reverts when a subsequent `recordMandateUse` is invoked with
    ///         metadata (principal / agent / kyaCredentialHash / maxTotalUsd /
    ///         expiresAt) that does not exactly match the binding image
    ///         registered on first use.
    error ImmutableFieldChanged(bytes32 mandateId);

    /// @notice Deploy the registry with a single admin authorised to grant
    ///         `TOKEN_ROLE` (to the RIVR token) and `RECOVERY_ROLE` (to the
    ///         principal's recovery key holder).
    /// @param admin DEFAULT_ADMIN_ROLE recipient. MUST NOT be the zero address.
    constructor(address admin) {
        require(admin != address(0), "RIVR-MR: admin zero");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @inheritdoc IRivierMandateRegistry
    function recordMandateUse(
        bytes32 mandateId,
        address principal,
        address agent,
        bytes32 kyaCredentialHash,
        uint256 maxTotalUsd,
        uint64 expiresAt,
        uint256 amountUsd
    ) external onlyRole(TOKEN_ROLE) {
        require(mandateId != bytes32(0), "RIVR-MR: id zero");

        MandateRecord storage rec = _records[mandateId];

        if (rec.principal == address(0)) {
            // First-use lazy registration.
            rec.principal = principal;
            rec.agent = agent;
            rec.kyaCredentialHash = kyaCredentialHash;
            rec.maxTotalUsd = maxTotalUsd;
            rec.expiresAt = expiresAt;
            _mandatesByPrincipal[principal].push(mandateId);
        } else {
            // Subsequent uses must match the binding image.
            if (
                rec.principal != principal ||
                rec.agent != agent ||
                rec.kyaCredentialHash != kyaCredentialHash ||
                rec.maxTotalUsd != maxTotalUsd ||
                rec.expiresAt != expiresAt
            ) {
                revert ImmutableFieldChanged(mandateId);
            }
        }

        if (rec.revoked) revert MandateAlreadyRevoked(mandateId);

        uint256 newTotal = rec.cumulativeSpentUsd + amountUsd;
        if (newTotal > rec.maxTotalUsd) {
            revert CumulativeCapExceeded(mandateId, newTotal, rec.maxTotalUsd);
        }
        rec.cumulativeSpentUsd = newTotal;

        emit MandateUsed(mandateId, principal, agent, amountUsd, newTotal);
    }

    /// @inheritdoc IRivierMandateRegistry
    function revokeMandate(bytes32 mandateId) external {
        MandateRecord storage rec = _records[mandateId];
        if (rec.principal == address(0)) revert UnknownMandate(mandateId);
        if (msg.sender != rec.principal) {
            revert NotPrincipal(mandateId, msg.sender, rec.principal);
        }
        if (rec.revoked) revert MandateAlreadyRevoked(mandateId);

        rec.revoked = true;
        emit MandateRevoked(mandateId, msg.sender, uint64(block.timestamp));
    }

    /// @inheritdoc IRivierMandateRegistry
    function revokeAllMandates(address principal) external onlyRole(RECOVERY_ROLE) {
        bytes32[] storage list = _mandatesByPrincipal[principal];
        uint256 len = list.length;
        for (uint256 i = 0; i < len; ++i) {
            MandateRecord storage rec = _records[list[i]];
            if (!rec.revoked) {
                rec.revoked = true;
            }
        }
        emit AllMandatesRevoked(principal, msg.sender, uint64(block.timestamp));
    }

    /// @inheritdoc IRivierMandateRegistry
    function cumulativeSpend(bytes32 mandateId) external view returns (uint256) {
        return _records[mandateId].cumulativeSpentUsd;
    }

    /// @inheritdoc IRivierMandateRegistry
    function recordOf(bytes32 mandateId) external view returns (MandateRecord memory) {
        return _records[mandateId];
    }

    /// @inheritdoc IRivierMandateRegistry
    /// @dev Unknown mandates (never recorded) return FALSE — they're
    ///      first-use mandates, not revoked. The token validates the
    ///      envelope signature + expiry directly on the envelope before
    ///      ever consulting this view; this view's job is to catch
    ///      explicit revocation OR a registered mandate whose recorded
    ///      expiry has passed (defensive — the envelope's expiresAt is
    ///      the authoritative time bound).
    function isRevokedOrExpired(bytes32 mandateId) external view returns (bool) {
        MandateRecord storage rec = _records[mandateId];
        if (rec.principal == address(0)) return false;
        if (rec.revoked) return true;
        if (rec.expiresAt <= block.timestamp) return true;
        return false;
    }

    /// @inheritdoc IRivierMandateRegistry
    function projectCumulative(bytes32 mandateId, uint256 additionalUsd)
        external
        view
        returns (uint256 projectedTotal, uint256 cap, bool wouldExceed)
    {
        MandateRecord storage rec = _records[mandateId];
        projectedTotal = rec.cumulativeSpentUsd + additionalUsd;
        cap = rec.maxTotalUsd;
        wouldExceed = projectedTotal > cap;
    }
}
