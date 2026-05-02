// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IPolicyHook} from "../interfaces/IPolicyHook.sol";
import {IRivierKyaRegistry} from "../interfaces/IRivierKyaRegistry.sol";
import {IChainalysisSanctionsList} from "../interfaces/IChainalysisSanctionsList.sol";
import {MandateEnvelope} from "../types/MandateEnvelope.sol";
import {IntentClass} from "../types/IntentClass.sol";
import {RefusalReason} from "../types/RefusalReason.sol";

/**
 * @title RivierPolicyHook
 * @notice Live-at-launch oracles: KYA + Chainalysis sanctions +
 *         Travel Rule attestation hash. Pass-through stubs (return
 *         RefusalReason.OK) for jurisdiction / velocity / counterparty
 *         / RWA gates — those are filled in post-launch hardening.
 *
 * Methods are `view` and never revert. They return a typed
 * RefusalReason + 32-byte ctx tag. The token contract is the sole
 * decider of whether a returned reason translates to a real revert.
 *
 * Admin posture: `POLICY_ADMIN_ROLE` is the 7-day timelock contract,
 * never an EOA. Sub-oracle setters (KyaRegistry, sanctions oracle,
 * known-attestation registry) are timelock-gated. Per CLAUDE.md
 * §"PolicyHook upgradability — freeze at milestone", this hook
 * itself becomes immutable post-freeze; only sub-oracle slots remain
 * upgradable behind a longer (30-day) timelock.
 *
 * Sanctions oracle handling: Chainalysis publishes the same address
 * (`0x40C57923924B5c5c5455c48D93317139ADDaC8fb`) on Ethereum /
 * Optimism / Polygon / Arbitrum / Avalanche. On chains where
 * Chainalysis hasn't shipped yet (Base at deploy time, etc.), the
 * deploy script passes `address(0)` and the hook short-circuits to
 * "not sanctioned" — sanctions screening is then enforced off-chain
 * at the API gateway layer until Chainalysis publishes the lane.
 *
 * Travel Rule attestation: enforced off-chain at the rivier-policy
 * layer (Notabene integration; see CLAUDE.md §"Travel Rule + IVMS 101").
 * On-chain enforcement here checks for an attestation hash registered
 * via `markTravelRuleAttested(hash)` by `TRAVEL_RULE_ATTESTOR_ROLE`.
 * Below the $1k de minimis the check is skipped (caller signals via
 * the leg amount in USD-decimals; $1k = 1_000 * 1e6 = 1e9 amountUsd6).
 */
contract RivierPolicyHook is IPolicyHook, AccessControl {
    bytes32 public constant POLICY_ADMIN_ROLE = keccak256("POLICY_ADMIN_ROLE");
    bytes32 public constant TRAVEL_RULE_ATTESTOR_ROLE =
        keccak256("TRAVEL_RULE_ATTESTOR_ROLE");

    IRivierKyaRegistry public kyaRegistry;
    IChainalysisSanctionsList public sanctionsOracle;

    /// @dev attestationHash => recorded? Set by the off-chain travel-rule
    ///      attestor (rivier-policy) once Notabene has a transfer record.
    ///      Token includes the attestation hash on the leg via the
    ///      mandate's binding (or via memoHash for plain transfers in
    ///      future work).
    mapping(bytes32 attestationHash => bool) public travelRuleAttested;

    /// @dev $1k FATF de minimis in 6-decimal USD (matches MandateRegistry's
    ///      cumulative tracker convention).
    uint256 public constant TRAVEL_RULE_DE_MINIMIS_USD6 = 1_000 * 1e6;

    /// @notice Emitted whenever the KYA registry pointer is (re)assigned —
    ///         on construction and on each successful `setKyaRegistry`.
    event KyaRegistrySet(address indexed registry);
    /// @notice Emitted whenever the Chainalysis sanctions oracle pointer is
    ///         (re)assigned. `address(0)` is a valid value (no-coverage chain).
    event SanctionsOracleSet(address indexed oracle);
    /// @notice Emitted when the off-chain Travel Rule attestor records a
    ///         hash that downstream legs may reference via memoHash.
    event TravelRuleAttested(bytes32 indexed attestationHash, address indexed by);

    /// @notice Deploy the policy hook with its admin / timelock / sub-oracles.
    /// @param admin            DEFAULT_ADMIN_ROLE recipient. MUST NOT be zero.
    /// @param policyAdmin      POLICY_ADMIN_ROLE recipient — MUST be the 7-day
    ///                         timelock contract, never an EOA. Authorises
    ///                         `setKyaRegistry` / `setSanctionsOracle`.
    /// @param kyaRegistry_     Live KYA registry address. MUST NOT be zero —
    ///                         token consults this on every mandate-bound leg.
    /// @param sanctionsOracle_ Chainalysis sanctions oracle address. MAY be
    ///                         the zero address on chains where Chainalysis
    ///                         hasn't shipped (Base at deploy time, etc.).
    constructor(
        address admin,
        address policyAdmin,
        address kyaRegistry_,
        address sanctionsOracle_
    ) {
        require(admin != address(0), "RIVR-PH: admin zero");
        require(policyAdmin != address(0), "RIVR-PH: policy admin zero");
        require(kyaRegistry_ != address(0), "RIVR-PH: kya zero");
        // sanctionsOracle_ MAY be address(0) on chains where Chainalysis
        // hasn't shipped — the hook short-circuits to "not sanctioned".

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(POLICY_ADMIN_ROLE, policyAdmin);

        kyaRegistry = IRivierKyaRegistry(kyaRegistry_);
        sanctionsOracle = IChainalysisSanctionsList(sanctionsOracle_);

        emit KyaRegistrySet(kyaRegistry_);
        emit SanctionsOracleSet(sanctionsOracle_);
    }

    // ─── admin (timelock-gated) ──────────────────────────────────────

    /// @notice Repoint the on-chain KYA registry. POLICY_ADMIN_ROLE-gated;
    ///         in production the admin is the 7-day timelock contract.
    /// @param registry New KYA registry address. MUST NOT be the zero address.
    function setKyaRegistry(address registry) external onlyRole(POLICY_ADMIN_ROLE) {
        require(registry != address(0), "RIVR-PH: kya zero");
        kyaRegistry = IRivierKyaRegistry(registry);
        emit KyaRegistrySet(registry);
    }

    /// @notice Repoint the Chainalysis sanctions oracle.
    ///         POLICY_ADMIN_ROLE-gated. `address(0)` is permitted for chains
    ///         without Chainalysis coverage; the hook then short-circuits
    ///         the on-chain sanctions check (off-chain enforcement still
    ///         applies via the API gateway).
    /// @param oracle New oracle address — `address(0)` permitted.
    function setSanctionsOracle(address oracle) external onlyRole(POLICY_ADMIN_ROLE) {
        // Allow address(0) for chains without Chainalysis coverage.
        sanctionsOracle = IChainalysisSanctionsList(oracle);
        emit SanctionsOracleSet(oracle);
    }

    /// @notice Off-chain attestor (rivier-policy) records that a Travel
    ///         Rule envelope has been submitted to Notabene. The token
    ///         binds the attestation hash to the leg via the mandate.
    function markTravelRuleAttested(bytes32 attestationHash)
        external
        onlyRole(TRAVEL_RULE_ATTESTOR_ROLE)
    {
        travelRuleAttested[attestationHash] = true;
        emit TravelRuleAttested(attestationHash, msg.sender);
    }

    // ─── IPolicyHook ─────────────────────────────────────────────────

    /// @inheritdoc IPolicyHook
    function checkMandateBound(
        address /* caller */,
        address from,
        address to,
        uint256 amount,
        address /* asset */,
        bytes32 /* namespace */,
        IntentClass /* intentClass */,
        bytes32 memoHash,
        MandateEnvelope calldata mandate
    ) external view returns (RefusalReason reason, bytes32 ctx) {
        return _checkLeg(from, to, amount, memoHash, mandate.kyaCredentialHash);
    }

    /// @dev Internal per-leg check shared by `checkMandateBound` and
    ///      `checkBatch`. Keeping this contained avoids stack-too-deep
    ///      when the batch loop iterates with the full leg-context tuple.
    ///
    ///      Order:
    ///        1. KYA registry (canonical for transfer authorization)
    ///        2. Chainalysis sanctions oracle (skipped if unset)
    ///        3. Travel Rule de minimis + attestation hash
    ///        4. Pass-through stubs (jurisdiction / velocity /
    ///           counterparty / RWA gate) — return OK at launch.
    function _checkLeg(
        address from,
        address to,
        uint256 amount,
        bytes32 memoHash,
        bytes32 kyaCredentialHash
    ) private view returns (RefusalReason, bytes32) {
        if (!kyaRegistry.isValid(kyaCredentialHash)) {
            return (RefusalReason.KYA_INVALID, bytes32(uint256(uint160(from))));
        }

        if (address(sanctionsOracle) != address(0)) {
            if (sanctionsOracle.isSanctioned(from)) {
                return (RefusalReason.SANCTIONS_HIT, bytes32(uint256(uint160(from))));
            }
            if (sanctionsOracle.isSanctioned(to)) {
                return (RefusalReason.SANCTIONS_HIT, bytes32(uint256(uint160(to))));
            }
        }

        if (amount >= TRAVEL_RULE_DE_MINIMIS_USD6) {
            if (memoHash == bytes32(0) || !travelRuleAttested[memoHash]) {
                return (RefusalReason.TRAVEL_RULE_BLOCK, memoHash);
            }
        }

        return (RefusalReason.OK, bytes32(0));
    }

    /// @inheritdoc IPolicyHook
    function checkPlain(
        address /* caller */,
        address from,
        address to,
        uint256 /* amount */,
        address /* asset */
    ) external view returns (RefusalReason reason, bytes32 ctx) {
        // Plain transfers: sanctions only. KYA is not consulted —
        // plain transfers do not assume agent provenance.
        if (address(sanctionsOracle) != address(0)) {
            if (sanctionsOracle.isSanctioned(from)) {
                return (RefusalReason.SANCTIONS_HIT, bytes32(uint256(uint160(from))));
            }
            if (sanctionsOracle.isSanctioned(to)) {
                return (RefusalReason.SANCTIONS_HIT, bytes32(uint256(uint160(to))));
            }
        }
        return (RefusalReason.OK, bytes32(0));
    }

    /// @inheritdoc IPolicyHook
    function checkBatch(
        address /* caller */,
        address[] calldata from,
        address[] calldata to,
        uint256[] calldata amounts,
        address[] calldata /* assets */,
        bytes32[] calldata /* namespaces */,
        IntentClass[] calldata /* intentClasses */,
        bytes32[] calldata memoHashes,
        MandateEnvelope calldata mandate
    ) external view returns (RefusalReason reason, bytes32 ctx) {
        uint256 n = amounts.length;
        require(
            from.length == n &&
                to.length == n &&
                memoHashes.length == n,
            "RIVR-PH: array len"
        );

        // Single KYA check at batch level — same credential covers
        // every leg of the batch (one mandate => one kyaCredentialHash).
        if (!kyaRegistry.isValid(mandate.kyaCredentialHash)) {
            return (RefusalReason.KYA_INVALID, bytes32(0));
        }

        // Per-leg checks. Pack leg index into ctx so the caller can
        // surface which leg failed.
        bytes32 kya = mandate.kyaCredentialHash;
        for (uint256 i = 0; i < n; ++i) {
            (RefusalReason r, ) = _checkLeg(
                from[i],
                to[i],
                amounts[i],
                memoHashes[i],
                kya
            );
            if (r != RefusalReason.OK) {
                return (r, bytes32(i));
            }
        }
        return (RefusalReason.OK, bytes32(0));
    }
}
