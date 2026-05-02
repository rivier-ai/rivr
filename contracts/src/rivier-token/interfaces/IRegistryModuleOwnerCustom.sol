// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IRegistryModuleOwnerCustom
 * @notice Minimal interface against Chainlink's `RegistryModuleOwnerCustom`.
 *
 * Deployed at a canonical address per chain (looked up in the chain's
 * Chainlink CCIP docs). Permissionless self-serve registration entry
 * point for CCT (Cross-Chain Token standard, CCIP v1.5+).
 *
 * Two registration paths exist:
 *
 *   - `registerAdminViaGetCCIPAdmin(token)` — calls `IGetCCIPAdmin(token).getCCIPAdmin()`
 *     and proposes that address as the token admin in `TokenAdminRegistry`.
 *     The msg.sender of THIS call must equal the value returned by
 *     `getCCIPAdmin()`. This is the path RIVR uses — see CLAUDE.md
 *     §"RIVR mainnet launch — CCIP CCT self-serve" for the rationale
 *     (`getCCIPAdmin()` is a dedicated multisig, separate from
 *     DEFAULT_ADMIN, so the role split survives the registration).
 *   - `registerAdminViaOwner(token)` — same but reads `Ownable.owner()`.
 *     We don't use this; RIVR is `AccessControl`-based, not `Ownable`.
 *
 * After registration, the admin must call `acceptAdminRole(token)` on
 * `TokenAdminRegistry` to finalise the binding.
 */
interface IRegistryModuleOwnerCustom {
    function registerAdminViaGetCCIPAdmin(address token) external;
    function registerAdminViaOwner(address token) external;
}
