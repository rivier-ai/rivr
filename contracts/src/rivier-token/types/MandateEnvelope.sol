// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title MandateEnvelope
 * @notice EIP-712 typed-data envelope a principal signs to authorize an agent to
 *         spend on its behalf. AP2-conformant in shape (the AP2 conformance shim in
 *         services/rivier-agent reads matching JSON envelopes off-the-wire).
 *
 * The envelope carries the constraints the policy chain enforces:
 *   - principal: the signer (the human / smart-account whose funds move)
 *   - agent:    the EOA/contract authorized to act under this mandate (may equal principal
 *               for self-mandates / mandate-less direct transfers)
 *   - kyaCredentialHash: the keccak256 of the principal's W3C VC issued by
 *               did:web:identity.rivier.ai. Token contract checks the on-chain
 *               KyaRegistry mirror against this hash (see CLAUDE.md §KYA dual source).
 *   - assetAllowlist: tokens this mandate is allowed to spend. address(this)
 *               (the RIVR token) MUST be in the list for RIVR-denominated transfers.
 *               address(0) sentinel means "any asset"; PolicyHook may further restrict.
 *   - maxPerTxUsd / maxTotalUsd: caps in 6-decimal USD (1e6 = $1.00).
 *               maxTotalUsd is enforced by the MandateRegistry's cumulative-spend
 *               counter; maxPerTxUsd is enforced inline.
 *   - notBefore / expiresAt: validity window (unix seconds).
 *   - mandateId: bytes32 unique per mandate. Constructed off-chain as
 *               keccak256(abi.encode(principal, agent, nonce)) — registry tracks
 *               cumulative spend and revocation against this id.
 *   - principalSignature / agentSignature: 65-byte ECDSA or EIP-1271 signatures.
 *               Token verifies both via OZ SignatureChecker, so smart-account
 *               principals are first-class.
 *
 * The struct hash uses the typehash:
 *   keccak256(
 *     "MandateEnvelope(address principal,address agent,bytes32 kyaCredentialHash,"
 *     "address[] assetAllowlist,uint256 maxPerTxUsd,uint256 maxTotalUsd,"
 *     "uint64 notBefore,uint64 expiresAt,bytes32 mandateId,bytes32 nonce)"
 *   )
 *
 * Off-chain consumers MUST encode `assetAllowlist` per EIP-712 v4 array rules
 * (keccak256 of the abi-encoded array of element hashes).
 */
struct MandateEnvelope {
    address principal;
    address agent;
    bytes32 kyaCredentialHash;
    address[] assetAllowlist;
    uint256 maxPerTxUsd;
    uint256 maxTotalUsd;
    uint64 notBefore;
    uint64 expiresAt;
    bytes32 mandateId;
    bytes32 nonce;
    bytes principalSignature;
    bytes agentSignature;
}

library MandateEnvelopeLib {
    /// @dev Asset address sentinel meaning "any asset allowed".
    address internal constant ANY_ASSET = address(0);

    /// @dev EIP-712 typehash. Must match the off-chain producer (curator AP2 builder).
    bytes32 internal constant MANDATE_TYPEHASH = keccak256(
        "MandateEnvelope(address principal,address agent,bytes32 kyaCredentialHash,"
        "address[] assetAllowlist,uint256 maxPerTxUsd,uint256 maxTotalUsd,"
        "uint64 notBefore,uint64 expiresAt,bytes32 mandateId,bytes32 nonce)"
    );

    /**
     * @notice Compute the EIP-712 struct hash of an envelope. Domain separator is
     *         applied by the verifier (OZ EIP712._hashTypedDataV4).
     */
    function structHash(MandateEnvelope calldata env) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                MANDATE_TYPEHASH,
                env.principal,
                env.agent,
                env.kyaCredentialHash,
                _hashAddressArray(env.assetAllowlist),
                env.maxPerTxUsd,
                env.maxTotalUsd,
                env.notBefore,
                env.expiresAt,
                env.mandateId,
                env.nonce
            )
        );
    }

    /// @notice Returns true iff `asset` is in `assetAllowlist`, or the list is the
    ///         single-element `[ANY_ASSET]` sentinel.
    function assetAllowed(MandateEnvelope calldata env, address asset) internal pure returns (bool) {
        uint256 len = env.assetAllowlist.length;
        if (len == 1 && env.assetAllowlist[0] == ANY_ASSET) return true;
        for (uint256 i = 0; i < len; ++i) {
            if (env.assetAllowlist[i] == asset) return true;
        }
        return false;
    }

    function _hashAddressArray(address[] calldata arr) private pure returns (bytes32) {
        // EIP-712 array encoding: keccak256(concat(keccak256(elem_i)) ...)
        // For value types, each elem is its 32-byte abi-encoding.
        bytes memory packed = new bytes(arr.length * 32);
        assembly {
            let dst := add(packed, 32)
            let len := arr.length
            // calldata array layout: arr.offset points to first element
            let src := arr.offset
            for { let i := 0 } lt(i, len) { i := add(i, 1) } {
                // Each address sits in a 32-byte calldata slot, left-padded.
                let v := calldataload(add(src, mul(i, 32)))
                mstore(add(dst, mul(i, 32)), v)
            }
        }
        return keccak256(packed);
    }
}
