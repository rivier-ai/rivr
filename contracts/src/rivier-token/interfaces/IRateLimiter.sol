// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IRateLimiter
 * @notice Per-lane cross-chain throughput limit.
 *
 * Mirrors the `RateLimiter.Config` struct used by Chainlink's
 * BurnMintTokenPool. The DON enforces this on outbound + inbound CCIP
 * messages independently: even if attestation is somehow compromised,
 * the rate limiter caps drain to `capacity` per epoch (refilled at
 * `rate` tokens/sec).
 *
 * Numbers below are conservative defaults for a brand-new stablecoin —
 * tighten further at mainnet launch and only raise via multisig
 * timelock once volume warrants it.
 */
interface IRateLimiter {
    struct Config {
        bool isEnabled;
        uint128 capacity; // bucket size in token's smallest unit (wei for 18-dec)
        uint128 rate;     // refill rate per second
    }
}
