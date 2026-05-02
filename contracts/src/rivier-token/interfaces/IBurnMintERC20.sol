// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IBurnMintERC20
 * @notice The minimal surface a CCT BurnMintTokenPool calls on a token.
 *
 * Chainlink's BurnMintTokenPool (in the chainlink-ccip lib) calls
 *   token.mint(account, amount)
 *   token.burn(amount)            // burns from the pool's own balance
 *   token.burnFrom(account, value) // some pools call this instead
 *
 * Any token that wants to ride the burn-and-mint CCT lane must expose
 * these and grant MINTER + BURNER roles to the pool contract. That's
 * what makes the cross-chain flow work: source chain burns the user's
 * tokens via the pool, CCIP delivers a message, destination chain's
 * pool mints fresh tokens to the user.
 */
interface IBurnMintERC20 {
    function mint(address account, uint256 amount) external;
    function burn(uint256 amount) external;
    function burnFrom(address account, uint256 amount) external;
}
