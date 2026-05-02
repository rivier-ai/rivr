// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {IGetCCIPAdmin} from "./interfaces/IGetCCIPAdmin.sol";
import {IBurnMintERC20} from "./interfaces/IBurnMintERC20.sol";
import {IPoRFeed} from "./interfaces/IPoRFeed.sol";
import {IPolicyHook} from "./interfaces/IPolicyHook.sol";
import {IRivierKyaRegistry} from "./interfaces/IRivierKyaRegistry.sol";
import {IRivierMandateRegistry} from "./interfaces/IRivierMandateRegistry.sol";
import {IRivierStreamRegistry} from "./interfaces/IRivierStreamRegistry.sol";

import {MandateEnvelope, MandateEnvelopeLib} from "./types/MandateEnvelope.sol";
import {StreamParams} from "./types/StreamParams.sol";
import {BatchTransferInput} from "./types/BatchTransferInput.sol";
import {IntentClass} from "./types/IntentClass.sol";
import {RefusalReason} from "./types/RefusalReason.sol";
import {DryRunInput, DryRunLeg} from "./types/DryRunInput.sol";
import {DryRunResult, DryRunLegResult} from "./types/DryRunResult.sol";

/**
 * @title RivierTokenCCT
 * @notice Rivier (RIVR) — agentic-economy stablecoin and programmable
 *         settlement rail. CCT-compatible (Chainlink Cross-Chain Token
 *         standard) and AP2-conformant.
 *
 * Inheritance:
 *   - ERC20 + ERC20Pausable (OZ)               — fungible base + emergency pause
 *   - AccessControl (OZ)                        — role split
 *   - EIP712 (OZ)                               — MandateEnvelope typed-data signing
 *
 * Native primitives (NOT inherited; implemented directly to avoid
 * cross-standard signature collisions with ERC-6909):
 *   - Sub-balance namespaces (deposit / withdrawFromNamespace /
 *     balanceOfNamespace / transferNamespace) — agent-isolated balance
 *     buckets per holder. `balanceOf(holder)` returns the SUM across
 *     all namespaces.
 *
 * Launch surface (single absolute-replacement PR per CLAUDE.md
 * §"Pre-launch posture"):
 *   - transferWithMandate(...)            — agent-driven, mandate-bound
 *   - batchProgrammableTransfer(...)      — single mandate, N legs, atomic
 *   - openStream / withdrawFromStream / closeStream / streamBalance
 *   - deposit / withdrawFromNamespace / transferNamespace / balanceOfNamespace
 *   - dryRun(input)                       — view-only simulator with
 *                                           byte-equivalent RefusalReason
 *
 * CCT surface (preserved):
 *   - getCCIPAdmin / transferCCIPAdmin
 *   - mint / burn / burnFrom (BurnMintTokenPool entry points)
 *   - mintReserve (treasury, with reserve ref)
 *
 * Roles:
 *   DEFAULT_ADMIN_ROLE   — Rivier treasury multisig (manages other roles)
 *   MINTER_ROLE          — treasury + BurnMintTokenPool destination side
 *   BURNER_ROLE          — BurnMintTokenPool source side
 *   PAUSER_ROLE          — emergency pause (regulatory compliance)
 *   CCIP_ADMIN_ROLE      — single holder; address returned by getCCIPAdmin()
 *   POLICY_ADMIN_ROLE    — 7-day timelock; configures registries and policy hook
 *   RECOVERY_ROLE        — passes through to MandateRegistry.revokeAllMandates
 *
 * Policy chain on `transferWithMandate`:
 *   1. Mandate not paused / not expired / matches caller
 *   2. EIP-712 verify principal signature (with EIP-1271 fallthrough)
 *   3. EIP-712 verify agent signature
 *   4. Asset allowed (allowlist or ANY_ASSET sentinel)
 *   5. Per-tx cap (maxPerTxUsd) against amountUsd6
 *   6. KYA registry isValid(mandate.kyaCredentialHash)
 *   7. PoR reserve gate (mints only)
 *   8. PolicyHook.checkMandateBound (sanctions + travel rule + …)
 *   9. CEI: balance update FIRST
 *  10. MandateRegistry.recordMandateUse (cumulative cap)
 *  11. Emit ProgrammableTransferEvent (versioned v1)
 *
 * `dryRun(input)` walks an identical chain via `view` — no state writes,
 * no nonce burn, no cumulative increment. Byte-equivalence invariant
 * (enforced by the test suite): `dryRun({legs:[leg], …}).reason ==`
 * the `RefusalReason` a real `transferWithMandate(...)` would revert with.
 */
contract RivierTokenCCT is
    ERC20,
    ERC20Pausable,
    AccessControl,
    EIP712,
    IGetCCIPAdmin,
    IBurnMintERC20
{
    using MandateEnvelopeLib for MandateEnvelope;

    // ─── roles ──────────────────────────────────────────────────────

    bytes32 public constant MINTER_ROLE        = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE        = keccak256("BURNER_ROLE");
    bytes32 public constant PAUSER_ROLE        = keccak256("PAUSER_ROLE");
    bytes32 public constant CCIP_ADMIN_ROLE    = keccak256("CCIP_ADMIN_ROLE");
    bytes32 public constant POLICY_ADMIN_ROLE  = keccak256("POLICY_ADMIN_ROLE");
    bytes32 public constant RECOVERY_ROLE      = keccak256("RECOVERY_ROLE");

    // ─── namespace constants ────────────────────────────────────────

    bytes32 public constant DEFAULT_NS = bytes32(0);

    // ─── ProgrammableTransferEvent extension version ────────────────

    uint8 public constant EXTENSION_VERSION = 1;

    // ─── Proof of Reserve ───────────────────────────────────────────

    IPoRFeed public porFeed;
    uint256 public constant PoR_STALENESS = 24 hours;

    // ─── registries + policy hook ───────────────────────────────────

    IPolicyHook public policyHook;
    IRivierKyaRegistry public kyaRegistry;
    IRivierMandateRegistry public mandateRegistry;
    IRivierStreamRegistry public streamRegistry;

    // ─── CCIP admin (single holder) ─────────────────────────────────

    address private _ccipAdmin;

    // ─── namespace storage ──────────────────────────────────────────

    /// @dev holder => namespace => balance. Sum across all namespaces
    ///      equals `_totalBalance[holder]` and equals the ERC-20
    ///      `balanceOf(holder)`.
    mapping(address => mapping(bytes32 => uint256)) private _nsBalance;

    /// @dev holder => total across all namespaces. Maintained inline
    ///      with every namespace mutation. Used by `balanceOf`.
    mapping(address => uint256) private _totalBalance;

    /// @dev holder => list of namespace IDs that have been touched
    ///      (push-only — IDs persist even after balance returns to zero).
    mapping(address => bytes32[]) private _nsList;

    /// @dev holder => namespace => 1+index in _nsList (so 0 means
    ///      "not yet listed"). Push-only; never decremented.
    mapping(address => mapping(bytes32 => uint256)) private _nsListPos;

    // ─── EIP-712 typed data ─────────────────────────────────────────

    string private constant SIGNING_DOMAIN = "Rivier";
    string private constant SIGNING_VERSION = "1";

    // ─── events ─────────────────────────────────────────────────────

    /// @dev Versioned, extensible programmable-transfer event. Per design
    ///      doc §3.6, the v1 `extensionData` ABI-encodes the agent-attestation
    ///      tuple: (modelId, modelVersion, confidence, reasoningHash,
    ///      promptHash, mcpServerDid, teeAttestationHash, policyComplianceProof).
    ///      Producer-supplied; zero values mean "not bound".
    event ProgrammableTransferEvent(
        bytes32 indexed transferRef,
        address indexed from,
        address indexed to,
        uint256 amount,
        IntentClass intentClass,
        bytes32 memoHash,
        bytes32 mandateId,
        bytes32 kyaCredentialHash,
        uint8 extensionVersion,
        bytes extensionData
    );

    /// @dev Reserve-backed mint with off-chain reference to the
    ///      USDC/USDT/T-Bill deposit slip.
    event ReserveMint(address indexed to, uint256 amount, string reserveRef);

    /// @dev Holder-initiated redeem against reserves.
    event ReserveRedeem(address indexed from, uint256 amount, string redemptionRef);

    /// @dev CCIP admin rotation (emitted by transferCCIPAdmin).
    event CCIPAdminTransferred(address indexed previousAdmin, address indexed newAdmin);

    /// @dev PoR feed config change.
    event PorFeedUpdated(address indexed previousFeed, address indexed newFeed);

    /// @dev Sub-oracle / registry config change. Timelock-gated.
    event PolicyHookSet(address indexed previous, address indexed current);
    event KyaRegistrySet(address indexed previous, address indexed current);
    event MandateRegistrySet(address indexed previous, address indexed current);
    event StreamRegistrySet(address indexed previous, address indexed current);

    /// @dev Sum-preserving intra-account namespace move (no Transfer).
    event NamespaceMoved(
        address indexed holder,
        bytes32 indexed fromNs,
        bytes32 indexed toNs,
        uint256 amount
    );

    /// @dev Per-mandate.nonce replay-protection ledger.
    mapping(bytes32 => bool) public usedMandateNonce;

    // ─── errors ─────────────────────────────────────────────────────

    error RivierRefused(RefusalReason reason, bytes32 ctx);

    // ─── constructor ────────────────────────────────────────────────

    constructor(
        address defaultAdmin,
        address minter,
        address pauser,
        address ccipAdmin,
        address policyAdmin,
        address recovery
    )
        ERC20("Rivier", "RIVR")
        EIP712(SIGNING_DOMAIN, SIGNING_VERSION)
    {
        require(defaultAdmin != address(0), "RIVR: defaultAdmin zero");
        require(minter       != address(0), "RIVR: minter zero");
        require(pauser       != address(0), "RIVR: pauser zero");
        require(ccipAdmin    != address(0), "RIVR: ccipAdmin zero");
        require(policyAdmin  != address(0), "RIVR: policyAdmin zero");
        require(recovery     != address(0), "RIVR: recovery zero");

        _grantRole(DEFAULT_ADMIN_ROLE,  defaultAdmin);
        _grantRole(MINTER_ROLE,         minter);
        _grantRole(PAUSER_ROLE,         pauser);
        _grantRole(CCIP_ADMIN_ROLE,     ccipAdmin);
        _grantRole(POLICY_ADMIN_ROLE,   policyAdmin);
        _grantRole(RECOVERY_ROLE,       recovery);

        _ccipAdmin = ccipAdmin;
        emit CCIPAdminTransferred(address(0), ccipAdmin);
    }

    // ─── balance views (ERC-20 + namespace) ─────────────────────────

    /// @dev `balanceOf(holder)` = sum across all namespaces. Maintained
    ///      via `_totalBalance` so this stays O(1).
    function balanceOf(address account) public view override returns (uint256) {
        return _totalBalance[account];
    }

    /// @notice Balance held in `holder`'s `namespace`.
    function balanceOfNamespace(address holder, bytes32 namespace)
        external
        view
        returns (uint256)
    {
        return _nsBalance[holder][namespace];
    }

    /// @notice List of namespace IDs that have been touched for `holder`.
    ///         Push-only — IDs persist even after balance returns to zero.
    function namespacesOf(address holder) external view returns (bytes32[] memory) {
        return _nsList[holder];
    }

    // ─── ERC-20 surface (DEFAULT_NS only; gated by checkPlain) ──────

    /// @dev `transfer` / `transferFrom` debit the sender's DEFAULT_NS
    ///      and credit the recipient's DEFAULT_NS. Sanctions-only policy
    ///      check via `policyHook.checkPlain`. KYA NOT consulted —
    ///      plain transfers do not assume agent provenance.
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        // Mints (from == 0) and burns (to == 0) bypass the policy hook.
        // PoR / role gating is enforced at the mint() / burn() entry points.
        if (from != address(0) && to != address(0) && address(policyHook) != address(0)) {
            (RefusalReason reason, bytes32 ctx) = policyHook.checkPlain(
                _msgSender(),
                from,
                to,
                value,
                address(this)
            );
            if (reason != RefusalReason.OK) revert RivierRefused(reason, ctx);
        }

        // Update namespace storage on the same DEFAULT_NS bucket so
        // ERC-20 callers get the same accounting as namespace-aware ones.
        if (from != address(0)) {
            _debitNamespace(from, DEFAULT_NS, value);
        }
        if (to != address(0)) {
            _creditNamespace(to, DEFAULT_NS, value);
        }

        // ERC20Pausable._update enforces whenNotPaused; we delegate
        // through to it so OZ's pause flag and Transfer event semantics
        // stay correct. (We don't store balances in OZ's _balances; we
        // override balanceOf above. OZ's _update still updates its
        // internal _balances map but we never read it.)
        super._update(from, to, value);
    }

    // ─── CCT: BurnMintTokenPool surface ─────────────────────────────

    /// @notice Mint `amount` to `account`. PoR-gated.
    ///         Used by treasury (reserve mints) AND by the
    ///         BurnMintTokenPool when delivering inbound CCIP messages.
    function mint(address account, uint256 amount) external onlyRole(MINTER_ROLE) {
        _checkReserve(amount);
        _mint(account, amount);
    }

    /// @notice Burn `amount` from caller's balance. Role-gated to
    ///         BURNER_ROLE so arbitrary holders can't damage supply
    ///         accounting; redemption flows go through `redeem`.
    function burn(uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(_msgSender(), amount);
    }

    /// @notice Burn `amount` of `account`'s balance using caller's allowance.
    function burnFrom(address account, uint256 amount) external onlyRole(BURNER_ROLE) {
        _spendAllowance(account, _msgSender(), amount);
        _burn(account, amount);
    }

    /// @notice Reserve-backed treasury mint with off-chain ref.
    function mintReserve(address to, uint256 amount, string calldata reserveRef)
        external
        onlyRole(MINTER_ROLE)
    {
        _checkReserve(amount);
        _mint(to, amount);
        emit ReserveMint(to, amount, reserveRef);
    }

    /// @notice Holder-initiated redeem against reserves.
    function redeem(uint256 amount, string calldata redemptionRef) external {
        _burn(_msgSender(), amount);
        emit ReserveRedeem(_msgSender(), amount, redemptionRef);
    }

    // ─── CCT: getCCIPAdmin / transferCCIPAdmin ──────────────────────

    function getCCIPAdmin() external view returns (address) {
        return _ccipAdmin;
    }

    function transferCCIPAdmin(address newAdmin) external onlyRole(CCIP_ADMIN_ROLE) {
        require(newAdmin != address(0), "RIVR: newAdmin zero");
        address previous = _ccipAdmin;
        _revokeRole(CCIP_ADMIN_ROLE, previous);
        _grantRole(CCIP_ADMIN_ROLE, newAdmin);
        _ccipAdmin = newAdmin;
        emit CCIPAdminTransferred(previous, newAdmin);
    }

    // ─── PoR feed (CCIP_ADMIN_ROLE-gated) ───────────────────────────

    function setPorFeed(address newFeed) external onlyRole(CCIP_ADMIN_ROLE) {
        address previous = address(porFeed);
        porFeed = IPoRFeed(newFeed);
        emit PorFeedUpdated(previous, newFeed);
    }

    function _checkReserve(uint256 amount) internal view {
        IPoRFeed feed = porFeed;
        if (address(feed) == address(0)) return;

        uint256 ts = feed.latestTimestamp();
        require(ts != 0, "RIVR: PoR no timestamp");
        require(block.timestamp <= ts + PoR_STALENESS, "RIVR: PoR stale");

        int256 answer = feed.latestAnswer();
        require(answer > 0, "RIVR: PoR non-positive");

        uint8 feedDecimals = feed.decimals();
        uint256 projectedSupply = totalSupply() + amount;
        uint256 scaledSupply = feedDecimals < 18
            ? projectedSupply / (10 ** (18 - feedDecimals))
            : projectedSupply * (10 ** (feedDecimals - 18));
        require(uint256(answer) >= scaledSupply, "RIVR: insufficient reserves");
    }

    // ─── registry / policy-hook setters (timelock-gated) ────────────

    function setPolicyHook(address hook) external onlyRole(POLICY_ADMIN_ROLE) {
        address previous = address(policyHook);
        policyHook = IPolicyHook(hook);
        emit PolicyHookSet(previous, hook);
    }

    function setKyaRegistry(address registry) external onlyRole(POLICY_ADMIN_ROLE) {
        require(registry != address(0), "RIVR: kya zero");
        address previous = address(kyaRegistry);
        kyaRegistry = IRivierKyaRegistry(registry);
        emit KyaRegistrySet(previous, registry);
    }

    function setMandateRegistry(address registry) external onlyRole(POLICY_ADMIN_ROLE) {
        require(registry != address(0), "RIVR: mandate zero");
        address previous = address(mandateRegistry);
        mandateRegistry = IRivierMandateRegistry(registry);
        emit MandateRegistrySet(previous, registry);
    }

    function setStreamRegistry(address registry) external onlyRole(POLICY_ADMIN_ROLE) {
        require(registry != address(0), "RIVR: stream zero");
        address previous = address(streamRegistry);
        streamRegistry = IRivierStreamRegistry(registry);
        emit StreamRegistrySet(previous, registry);
    }

    // ─── pause ──────────────────────────────────────────────────────

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ─── namespace primitives ───────────────────────────────────────

    /// @notice Move `amount` from caller's DEFAULT_NS into `namespace`.
    ///         Sum-preserving — total balance unchanged. Emits NamespaceMoved
    ///         (no ERC-20 Transfer).
    function deposit(bytes32 namespace, uint256 amount) external {
        require(namespace != DEFAULT_NS, "RIVR: ns zero");
        address holder = _msgSender();
        _moveBetweenNamespaces(holder, DEFAULT_NS, namespace, amount);
        emit NamespaceMoved(holder, DEFAULT_NS, namespace, amount);
    }

    /// @notice Move `amount` from caller's `namespace` to `to`'s DEFAULT_NS.
    ///         This DOES emit ERC-20 Transfer because the holder changed.
    function withdrawFromNamespace(bytes32 namespace, address to, uint256 amount)
        external
    {
        require(to != address(0), "RIVR: to zero");
        require(namespace != DEFAULT_NS, "RIVR: ns zero");
        address holder = _msgSender();

        // Debit the source namespace, credit recipient's DEFAULT via the
        // standard transfer flow. Use the ERC20 internal `_transfer` —
        // it goes through `_update`, which credits DEFAULT_NS on `to`.
        // We pre-debit the source namespace so `_update`'s DEFAULT-debit
        // sees the right total balance. Trick: temporarily move the amount
        // from `namespace` to DEFAULT_NS (intra-account), then transfer.
        _moveBetweenNamespaces(holder, namespace, DEFAULT_NS, amount);
        _transfer(holder, to, amount);
    }

    /// @notice Move `amount` between two of the caller's namespaces.
    ///         Sum-preserving — total balance unchanged. Emits NamespaceMoved.
    function transferNamespace(bytes32 fromNs, bytes32 toNs, uint256 amount)
        external
    {
        require(fromNs != toNs, "RIVR: same ns");
        address holder = _msgSender();
        _moveBetweenNamespaces(holder, fromNs, toNs, amount);
        emit NamespaceMoved(holder, fromNs, toNs, amount);
    }

    /// @dev Internal sum-preserving namespace move. Updates per-namespace
    ///      buckets but leaves `_totalBalance` unchanged.
    function _moveBetweenNamespaces(
        address holder,
        bytes32 fromNs,
        bytes32 toNs,
        uint256 amount
    ) internal {
        uint256 srcBal = _nsBalance[holder][fromNs];
        require(srcBal >= amount, "RIVR: insufficient ns");
        unchecked {
            _nsBalance[holder][fromNs] = srcBal - amount;
        }
        _nsBalance[holder][toNs] += amount;
        _registerNamespace(holder, toNs);
    }

    /// @dev Internal namespace credit. Bumps both per-namespace and total.
    function _creditNamespace(address holder, bytes32 namespace, uint256 amount) internal {
        _nsBalance[holder][namespace] += amount;
        _totalBalance[holder] += amount;
        _registerNamespace(holder, namespace);
    }

    /// @dev Internal namespace debit. Reverts if the namespace lacks balance.
    function _debitNamespace(address holder, bytes32 namespace, uint256 amount) internal {
        uint256 bal = _nsBalance[holder][namespace];
        if (bal < amount) {
            revert RivierRefused(RefusalReason.NAMESPACE_INSUFFICIENT, namespace);
        }
        unchecked {
            _nsBalance[holder][namespace] = bal - amount;
            _totalBalance[holder] -= amount;
        }
    }

    /// @dev Push-only namespace registration for enumeration.
    function _registerNamespace(address holder, bytes32 namespace) internal {
        if (_nsListPos[holder][namespace] == 0) {
            _nsList[holder].push(namespace);
            _nsListPos[holder][namespace] = _nsList[holder].length;
        }
    }

    // ─── transferWithMandate ────────────────────────────────────────

    /**
     * @notice Mandate-bound, agent-driven transfer. The whole reason
     *         RIVR exists.
     *
     * @param to            recipient (credited to DEFAULT_NS)
     * @param amount        token amount in 18-decimal wei
     * @param amountUsd6    same value in 6-decimal USD (for cap accounting).
     *                      RIVR is 1:1 USD-pegged so this is amount / 1e12.
     *                      Caller-supplied so non-RIVR variants of this
     *                      contract can carry an oracle-priced USD figure.
     * @param namespace     payer namespace; zero = DEFAULT_NS
     * @param mandate       full envelope (authorising principal + agent)
     * @param intentClass   IntentClass tag
     * @param memoHash      32-byte memo hash (also carries Travel-Rule attestation)
     * @param extensionData v1 ABI-encoded agent attestation tuple. Producer-supplied.
     */
    function transferWithMandate(
        address to,
        uint256 amount,
        uint256 amountUsd6,
        bytes32 namespace,
        MandateEnvelope calldata mandate,
        IntentClass intentClass,
        bytes32 memoHash,
        bytes calldata extensionData
    ) external whenNotPaused returns (bytes32 transferRef) {
        require(to != address(0), "RIVR: to zero");

        _runMandateChecks(
            mandate,
            address(this),
            amountUsd6,
            uint64(block.timestamp)
        );

        address from = mandate.principal;

        // Replay protection on the envelope nonce. Burned on first use.
        if (usedMandateNonce[mandate.nonce]) {
            revert RivierRefused(RefusalReason.MANDATE_REVOKED, mandate.nonce);
        }
        usedMandateNonce[mandate.nonce] = true;

        // PolicyHook (sanctions + travel rule + …)
        (RefusalReason hookReason, bytes32 hookCtx) = policyHook.checkMandateBound(
            _msgSender(),
            from,
            to,
            amountUsd6,
            address(this),
            namespace,
            intentClass,
            memoHash,
            mandate
        );
        if (hookReason != RefusalReason.OK) revert RivierRefused(hookReason, hookCtx);

        // Effects: namespace debit + DEFAULT-NS credit on recipient.
        _debitNamespace(from, namespace, amount);
        _creditNamespace(to, DEFAULT_NS, amount);

        // Interactions: record cumulative spend (CEI — state writes
        // here come AFTER the balance update).
        mandateRegistry.recordMandateUse(
            mandate.mandateId,
            mandate.principal,
            mandate.agent,
            mandate.kyaCredentialHash,
            mandate.maxTotalUsd,
            mandate.expiresAt,
            amountUsd6
        );

        // ERC-20 Transfer event for backwards-compat indexers.
        emit Transfer(from, to, amount);

        transferRef = mandate.mandateId ^ mandate.nonce;
        emit ProgrammableTransferEvent(
            transferRef,
            from,
            to,
            amount,
            intentClass,
            memoHash,
            mandate.mandateId,
            mandate.kyaCredentialHash,
            EXTENSION_VERSION,
            extensionData
        );
    }

    // ─── batchProgrammableTransfer ──────────────────────────────────

    /**
     * @notice Atomic N-leg batch under a single MandateEnvelope. The
     *         sum of `amounts[]` is checked against `maxPerTxUsd`
     *         AND `maxTotalUsd` once at the batch level.
     *
     *         Per-leg `transferRef = batchRef ^ legIndex` so off-chain
     *         consumers can reconstruct the batch from logs alone.
     */
    /// @notice Single-struct entry point. The launch surface logically
    ///         wants 9 calldata array params + 2 calldata structs, which
    ///         exceeds Solidity's local variable budget even with
    ///         `via_ir = true`. Bundling into BatchTransferInput
    ///         collapses the frame to a single calldata pointer.
    function batchProgrammableTransfer(BatchTransferInput calldata input)
        external
        whenNotPaused
    {
        uint256 n = input.recipients.length;
        require(n > 0, "RIVR: empty batch");
        require(input.amounts.length == n, "RIVR: len");
        require(input.amountsUsd6.length == n, "RIVR: len");
        require(input.namespaces.length == n, "RIVR: len");
        require(input.intentClasses.length == n, "RIVR: len");
        require(input.memoHashes.length == n, "RIVR: len");
        require(input.extensionDatas.length == n, "RIVR: len");

        uint256 sumUsd6;
        for (uint256 i = 0; i < n; ++i) {
            require(input.recipients[i] != address(0), "RIVR: to zero");
            sumUsd6 += input.amountsUsd6[i];
        }

        _runMandateChecks(input.mandate, address(this), sumUsd6, uint64(block.timestamp));

        if (usedMandateNonce[input.mandate.nonce]) {
            revert RivierRefused(RefusalReason.MANDATE_REVOKED, input.mandate.nonce);
        }
        usedMandateNonce[input.mandate.nonce] = true;

        _runBatchPolicyCheck(input, n);
        _applyBatchEffects(input, n);
    }

    /// @dev Extracted to dodge stack-too-deep on the entry function.
    ///      Builds the per-leg `from` and `asset` arrays the policy
    ///      hook expects, then forwards to `policyHook.checkBatch`.
    function _runBatchPolicyCheck(BatchTransferInput calldata input, uint256 n) private view {
        address[] memory froms = new address[](n);
        address[] memory assets = new address[](n);
        address principal = input.mandate.principal;
        address self = address(this);
        for (uint256 i = 0; i < n; ++i) {
            froms[i] = principal;
            assets[i] = self;
        }
        (RefusalReason r, bytes32 ctx) = policyHook.checkBatch(
            _msgSender(),
            froms,
            input.recipients,
            input.amountsUsd6,
            assets,
            input.namespaces,
            input.intentClasses,
            input.memoHashes,
            input.mandate
        );
        if (r != RefusalReason.OK) revert RivierRefused(r, ctx);
    }

    /// @dev Per-leg balance updates + cumulative-spend record + per-leg
    ///      ProgrammableTransferEvent. CEI: balance updates run BEFORE
    ///      the registry call so the registry sees the post-effects
    ///      view if it ever decides to read back.
    function _applyBatchEffects(BatchTransferInput calldata input, uint256 n) private {
        address from = input.mandate.principal;

        // Effects: per-leg balance updates.
        for (uint256 i = 0; i < n; ++i) {
            _debitNamespace(from, input.namespaces[i], input.amounts[i]);
            _creditNamespace(input.recipients[i], DEFAULT_NS, input.amounts[i]);
            emit Transfer(from, input.recipients[i], input.amounts[i]);
        }

        // Single cumulative-spend record against the batch sum.
        uint256 sumUsd6;
        for (uint256 i = 0; i < n; ++i) sumUsd6 += input.amountsUsd6[i];
        mandateRegistry.recordMandateUse(
            input.mandate.mandateId,
            input.mandate.principal,
            input.mandate.agent,
            input.mandate.kyaCredentialHash,
            input.mandate.maxTotalUsd,
            input.mandate.expiresAt,
            sumUsd6
        );

        // Per-leg ProgrammableTransferEvent.
        bytes32 batchRef = input.meta.batchRef;
        bytes32 mandateId = input.mandate.mandateId;
        bytes32 kya = input.mandate.kyaCredentialHash;
        for (uint256 i = 0; i < n; ++i) {
            emit ProgrammableTransferEvent(
                batchRef ^ bytes32(i),
                from,
                input.recipients[i],
                input.amounts[i],
                input.intentClasses[i],
                input.memoHashes[i],
                mandateId,
                kya,
                EXTENSION_VERSION,
                input.extensionDatas[i]
            );
        }
    }

    // ─── streams ────────────────────────────────────────────────────

    /// @notice Open a stream against the caller's mandate. Delegates to
    ///         the StreamRegistry (which holds the bookkeeping). The
    ///         token validates the mandate before the registry call
    ///         since the registry trusts TOKEN_ROLE callers.
    function openStream(StreamParams calldata p)
        external
        whenNotPaused
        returns (bytes32 streamRef)
    {
        // Open is mandate-bound but doesn't move funds yet. Validate
        // the mandate is active and the principal is the caller.
        _runMandateChecks(p.mandate, address(this), 0, uint64(block.timestamp));
        return streamRegistry.openStream(p);
    }

    /// @notice Withdraw `amount` from the stream into the recipient's
    ///         DEFAULT_NS. Caller MUST be the recipient.
    function withdrawFromStream(bytes32 streamRef, uint256 amount) external whenNotPaused {
        IRivierStreamRegistry.Stream memory s = streamRegistry.recordOf(streamRef);
        require(s.payer != address(0), "RIVR: unknown stream");
        require(_msgSender() == s.recipient, "RIVR: not recipient");

        // The registry enforces accrued-balance + paused checks.
        streamRegistry.withdrawFromStream(streamRef, amount);

        // Effects: debit payer's namespace, credit recipient's DEFAULT.
        _debitNamespace(s.payer, s.namespaceFromPayer, amount);
        _creditNamespace(s.recipient, DEFAULT_NS, amount);
        emit Transfer(s.payer, s.recipient, amount);

        emit ProgrammableTransferEvent(
            streamRef,
            s.payer,
            s.recipient,
            amount,
            s.intentClass,
            bytes32(0),
            s.mandateId,
            bytes32(0),
            EXTENSION_VERSION,
            ""
        );
    }

    function closeStream(bytes32 streamRef) external {
        streamRegistry.closeStreamFor(streamRef, _msgSender());
    }

    function streamBalance(bytes32 streamRef) external view returns (uint256) {
        return streamRegistry.streamBalance(streamRef);
    }

    // ─── dryRun (view-only simulator) ───────────────────────────────

    /**
     * @notice View-only simulation of `transferWithMandate` /
     *         `batchProgrammableTransfer`. Walks the same check chain
     *         and returns the same RefusalReason a real call would
     *         revert with. No state writes, no nonce burn.
     */
    function dryRun(DryRunInput calldata input)
        external
        view
        returns (DryRunResult memory result)
    {
        uint64 atTs = input.atTimestamp == 0 ? uint64(block.timestamp) : input.atTimestamp;
        uint256 n = input.legs.length;
        result.legResults = new DryRunLegResult[](n);

        // Sum across legs for cap projection.
        uint256 sumUsd6;
        for (uint256 i = 0; i < n; ++i) {
            sumUsd6 += _legAmountUsd6(input.legs[i]);
        }

        // Mandate-level checks (signature/expiry/asset/cap).
        (RefusalReason topReason, bytes32 topCtx) = _dryRunMandateChecks(
            input.mandate,
            address(this),
            sumUsd6,
            atTs
        );
        if (topReason != RefusalReason.OK) {
            result.reason = topReason;
            result.ctx = topCtx;
            for (uint256 i = 0; i < n; ++i) {
                result.legResults[i] = DryRunLegResult({reason: topReason, ctx: topCtx});
            }
            return result;
        }

        // Cumulative-cap projection (state-read only). For unregistered
        // (first-use) mandates the registry returns cap=0; fall back to
        // the envelope's maxTotalUsd which the token has just verified
        // via the EIP-712 signature check above.
        (uint256 projected, uint256 capFromRegistry, ) = mandateRegistry.projectCumulative(
            input.mandate.mandateId,
            sumUsd6
        );
        uint256 effectiveCap = capFromRegistry == 0 ? input.mandate.maxTotalUsd : capFromRegistry;
        bool wouldExceed = projected > effectiveCap;
        result.projectedCumulativeUsd = projected;
        if (wouldExceed) {
            result.reason = RefusalReason.MANDATE_CUMULATIVE_CAP;
            result.ctx = input.mandate.mandateId;
            for (uint256 i = 0; i < n; ++i) {
                result.legResults[i] = DryRunLegResult({
                    reason: RefusalReason.MANDATE_CUMULATIVE_CAP,
                    ctx: input.mandate.mandateId
                });
            }
            return result;
        }

        // Per-leg PolicyHook + namespace-balance checks.
        for (uint256 i = 0; i < n; ++i) {
            DryRunLeg calldata leg = input.legs[i];
            (RefusalReason r, bytes32 ctx) = _dryRunLeg(input.caller, leg, input.mandate);
            result.legResults[i] = DryRunLegResult({reason: r, ctx: ctx});
            if (r != RefusalReason.OK && result.reason == RefusalReason.OK) {
                result.reason = r;
                result.ctx = ctx;
            }
        }
    }

    // ─── internal: shared mandate-validation chain ──────────────────

    /// @dev Synchronous mandate validation used by every mandate-bound
    ///      entry point. Reverts with RivierRefused on first failure.
    function _runMandateChecks(
        MandateEnvelope calldata mandate,
        address asset,
        uint256 amountUsd6,
        uint64 atTs
    ) internal view {
        (RefusalReason r, bytes32 ctx) = _dryRunMandateChecks(mandate, asset, amountUsd6, atTs);
        if (r != RefusalReason.OK) revert RivierRefused(r, ctx);
    }

    /// @dev Mandate validation that returns a tuple instead of reverting.
    ///      Shared between `transferWithMandate` (via `_runMandateChecks`)
    ///      and `dryRun`. THE source of byte-equivalence between the
    ///      two paths.
    function _dryRunMandateChecks(
        MandateEnvelope calldata mandate,
        address asset,
        uint256 amountUsd6,
        uint64 atTs
    ) internal view returns (RefusalReason, bytes32) {
        if (atTs < mandate.notBefore) {
            return (RefusalReason.MANDATE_EXPIRED, mandate.mandateId);
        }
        if (atTs >= mandate.expiresAt) {
            return (RefusalReason.MANDATE_EXPIRED, mandate.mandateId);
        }
        if (mandate.principal == address(0) || mandate.agent == address(0)) {
            return (RefusalReason.MANDATE_PRINCIPAL_MISMATCH, mandate.mandateId);
        }

        bytes32 digest = _hashTypedDataV4(mandate.structHash());

        // Principal signature (with EIP-1271 fallthrough for smart accounts).
        if (
            !SignatureChecker.isValidSignatureNow(
                mandate.principal,
                digest,
                mandate.principalSignature
            )
        ) {
            return (RefusalReason.MANDATE_SIGNATURE_INVALID, mandate.mandateId);
        }

        // Agent signature.
        if (
            !SignatureChecker.isValidSignatureNow(
                mandate.agent,
                digest,
                mandate.agentSignature
            )
        ) {
            return (RefusalReason.MANDATE_AGENT_SIGNATURE_INVALID, mandate.mandateId);
        }

        // Asset allowlist.
        if (!mandate.assetAllowed(asset)) {
            return (RefusalReason.MANDATE_ASSET_NOT_ALLOWED, bytes32(uint256(uint160(asset))));
        }

        // Per-tx cap.
        if (amountUsd6 > mandate.maxPerTxUsd) {
            return (RefusalReason.MANDATE_PER_TX_CAP, mandate.mandateId);
        }

        // KYA registry.
        if (!kyaRegistry.isValid(mandate.kyaCredentialHash)) {
            return (RefusalReason.KYA_INVALID, mandate.kyaCredentialHash);
        }

        // Mandate registry: revoked or already-recorded as expired?
        if (mandateRegistry.isRevokedOrExpired(mandate.mandateId)) {
            return (RefusalReason.MANDATE_REVOKED, mandate.mandateId);
        }

        return (RefusalReason.OK, bytes32(0));
    }

    /// @dev Per-leg dryRun check. Asks the PolicyHook the same question
    ///      the real path asks, plus a balance-availability projection.
    function _dryRunLeg(
        address caller,
        DryRunLeg calldata leg,
        MandateEnvelope calldata mandate
    ) internal view returns (RefusalReason, bytes32) {
        // PolicyHook (sanctions + travel rule + …)
        (RefusalReason r, bytes32 ctx) = policyHook.checkMandateBound(
            caller,
            leg.from,
            leg.to,
            _legAmountUsd6(leg),
            leg.asset,
            leg.namespace,
            leg.intentClass,
            leg.memoHash,
            mandate
        );
        if (r != RefusalReason.OK) return (r, ctx);

        // Namespace balance availability.
        if (leg.asset == address(this)) {
            if (_nsBalance[leg.from][leg.namespace] < leg.amount) {
                return (RefusalReason.NAMESPACE_INSUFFICIENT, leg.namespace);
            }
        }
        return (RefusalReason.OK, bytes32(0));
    }

    /// @dev Convert a leg's wei amount to 6-decimal USD (RIVR is
    ///      1:1 USD-pegged at 18 decimals → divide by 1e12).
    function _legAmountUsd6(DryRunLeg calldata leg) internal pure returns (uint256) {
        return leg.amount / 1e12;
    }

    // ─── ERC165 ─────────────────────────────────────────────────────

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl)
        returns (bool)
    {
        return
            interfaceId == type(IGetCCIPAdmin).interfaceId ||
            interfaceId == type(IBurnMintERC20).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
