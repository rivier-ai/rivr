// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IGetCCIPAdmin
 * @notice One of two ways a token can declare its CCIP admin.
 *
 * Per Chainlink's CCT (Cross-Chain Token) standard, when a token is
 * registered on the TokenAdminRegistry the registry calls one of:
 *   - getCCIPAdmin() returns (address)  [this interface]
 *   - owner() returns (address)         [Ownable fallback]
 *
 * The address returned is the *only* party that can `proposeAdminRole`
 * on the registry. After they `acceptAdminRole`, that address can call
 * `setPool`, set rate limits, and so on.
 *
 * RIVR uses this interface (rather than Ownable) because we want a
 * dedicated CCIP-admin role that's separate from the token's
 * DEFAULT_ADMIN_ROLE — the CCIP admin should be a multisig that only
 * touches cross-chain config, never mint/burn or pause.
 */
interface IGetCCIPAdmin {
    function getCCIPAdmin() external view returns (address);
}
