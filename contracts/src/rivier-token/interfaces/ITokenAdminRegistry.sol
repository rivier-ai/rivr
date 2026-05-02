// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ITokenAdminRegistry
 * @notice Minimal interface against Chainlink's TokenAdminRegistry.
 *
 * Deployed at a canonical address per chain (looked up in the chain's
 * Chainlink CCIP docs). This is the contract that decides which pool
 * is allowed to burn/mint a given token on a given chain.
 *
 * CCT registration flow (run by `IGetCCIPAdmin.getCCIPAdmin()` or by
 * the token's `Ownable.owner()`):
 *
 *   1. proposeAdminRole(token, admin)   - claim the admin role
 *   2. acceptAdminRole(token)            - accept it (separate tx for safety)
 *   3. setPool(token, pool)              - bind a BurnMintTokenPool
 *
 * After step 3, CCIP routes a cross-chain transfer of `token` through
 * `pool` on this chain. Each pool itself owns the per-lane RateLimiter
 * and chain-update config.
 */
interface ITokenAdminRegistry {
    function proposeAdminRole(address localToken, address administrator) external;
    function acceptAdminRole(address localToken) external;
    function setPool(address localToken, address pool) external;
    function getPool(address localToken) external view returns (address);
    function getTokenConfig(address localToken)
        external
        view
        returns (
            address administrator,
            address pendingAdministrator,
            address tokenPool
        );
}
