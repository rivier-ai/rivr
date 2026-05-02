// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {RivierTokenCCT} from "../../src/rivier-token/RivierTokenCCT.sol";
import {RivierKyaRegistry} from "../../src/rivier-token/registries/RivierKyaRegistry.sol";
import {RivierMandateRegistry} from "../../src/rivier-token/registries/RivierMandateRegistry.sol";
import {RivierStreamRegistry} from "../../src/rivier-token/registries/RivierStreamRegistry.sol";
import {RivierPolicyHook} from "../../src/rivier-token/policy/RivierPolicyHook.sol";

import {MandateEnvelope, MandateEnvelopeLib} from "../../src/rivier-token/types/MandateEnvelope.sol";
import {IntentClass, IntentClasses} from "../../src/rivier-token/types/IntentClass.sol";
import {RefusalReason} from "../../src/rivier-token/types/RefusalReason.sol";

import {IChainalysisSanctionsList} from "../../src/rivier-token/interfaces/IChainalysisSanctionsList.sol";
import {IPoRFeed} from "../../src/rivier-token/interfaces/IPoRFeed.sol";

/// @dev Mock Chainalysis oracle. Default: nobody sanctioned. Set via `setSanctioned`.
contract MockSanctionsOracle is IChainalysisSanctionsList {
    mapping(address => bool) private _sanctioned;
    function setSanctioned(address a, bool flag) external { _sanctioned[a] = flag; }
    function isSanctioned(address a) external view returns (bool) { return _sanctioned[a]; }
}

/// @dev Mock Chainlink PoR feed. Configure via `set(answer, ts)`.
contract MockPoRFeed is IPoRFeed {
    int256 private _answer;
    uint256 private _timestamp;
    uint8 private _decimals;

    constructor(uint8 d) { _decimals = d; }
    function set(int256 ans, uint256 ts) external { _answer = ans; _timestamp = ts; }
    function decimals() external view returns (uint8) { return _decimals; }
    function latestAnswer() external view returns (int256) { return _answer; }
    function latestTimestamp() external view returns (uint256) { return _timestamp; }
}

/// @notice Shared test scaffolding for the RIVR launch suite.
///
/// Provides:
///   - Deployed token, all 3 registries, the policy hook, mock sanctions oracle
///   - Role-grants the deploy script does (TOKEN_ROLE on registries, etc.)
///   - Principal/agent EOAs with deterministic private keys for EIP-712 signing
///   - A helper to mint funded RIVR balances for tests
///   - A helper to build + sign a MandateEnvelope (correct EIP-712 digest)
///   - A helper to upsert a fresh KYA credential
///   - A helper to register a mandate's metadata at MandateRegistry first-use
///     (we go via a sentinel `recordMandateUse(.., 0)` from the token role —
///     impersonating with vm.prank since the token is the only TOKEN_ROLE holder)
///
/// Address layout (from Forge's `makeAddrAndKey`):
///   PRINCIPAL  — mandate principal (signs the envelope's principal sig)
///   AGENT      — mandate agent (signs the envelope's agent sig, also msg.sender)
///   RECIPIENT  — payee on transferWithMandate
///   TREASURY   — DEFAULT_ADMIN_ROLE / MINTER_ROLE / pauser
///   CCIP_ADMIN — CCIP_ADMIN_ROLE (deliberately distinct from treasury)
///   POLICY_ADMIN — POLICY_ADMIN_ROLE
///   RECOVERY   — RECOVERY_ROLE on token + registry
///   KYA_SYNC   — KYA_SYNC_ROLE on KyaRegistry
///   ATTESTOR   — TRAVEL_RULE_ATTESTOR_ROLE on PolicyHook
abstract contract RivierTestBase is Test {
    using MandateEnvelopeLib for MandateEnvelope;

    RivierTokenCCT internal token;
    RivierKyaRegistry internal kya;
    RivierMandateRegistry internal mandates;
    RivierStreamRegistry internal streams;
    RivierPolicyHook internal hook;
    MockSanctionsOracle internal sanctions;

    address internal TREASURY;
    address internal CCIP_ADMIN;
    address internal POLICY_ADMIN;
    address internal RECOVERY;
    address internal KYA_SYNC;
    address internal ATTESTOR;
    address internal RECIPIENT;

    address internal PRINCIPAL;
    uint256 internal PRINCIPAL_PK;
    address internal AGENT;
    uint256 internal AGENT_PK;

    bytes32 internal constant DEFAULT_NS = bytes32(0);

    function setUp() public virtual {
        TREASURY     = makeAddr("treasury");
        CCIP_ADMIN   = makeAddr("ccip_admin");
        POLICY_ADMIN = makeAddr("policy_admin");
        RECOVERY     = makeAddr("recovery");
        KYA_SYNC     = makeAddr("kya_sync");
        ATTESTOR     = makeAddr("attestor");
        RECIPIENT    = makeAddr("recipient");

        (PRINCIPAL, PRINCIPAL_PK) = makeAddrAndKey("principal");
        (AGENT,     AGENT_PK)     = makeAddrAndKey("agent");

        // Deploy registries
        kya = new RivierKyaRegistry(TREASURY, KYA_SYNC);
        mandates = new RivierMandateRegistry(TREASURY);
        streams = new RivierStreamRegistry(TREASURY);

        // Mock sanctions oracle (default: nobody sanctioned)
        sanctions = new MockSanctionsOracle();

        // Policy hook
        hook = new RivierPolicyHook(TREASURY, POLICY_ADMIN, address(kya), address(sanctions));

        // Token (6-arg constructor)
        token = new RivierTokenCCT(
            TREASURY,    // defaultAdmin
            TREASURY,    // minter
            TREASURY,    // pauser
            CCIP_ADMIN,  // ccipAdmin
            POLICY_ADMIN,// policyAdmin
            RECOVERY     // recovery
        );

        // Wire registries + policy hook into token (POLICY_ADMIN_ROLE-gated)
        vm.startPrank(POLICY_ADMIN);
        token.setKyaRegistry(address(kya));
        token.setMandateRegistry(address(mandates));
        token.setStreamRegistry(address(streams));
        token.setPolicyHook(address(hook));
        vm.stopPrank();

        // Cross-registry role grants (mirrors deploy script Step 5)
        vm.startPrank(TREASURY);
        mandates.grantRole(mandates.TOKEN_ROLE(), address(token));
        mandates.grantRole(mandates.RECOVERY_ROLE(), RECOVERY);
        streams.grantRole(streams.TOKEN_ROLE(), address(token));
        streams.grantRole(streams.POLICY_HOOK_ROLE(), address(hook));
        vm.stopPrank();

        // Travel rule attestor role on the hook. Read the role constant first
        // so the staticcall doesn't consume the next vm.prank.
        bytes32 attestorRole = hook.TRAVEL_RULE_ATTESTOR_ROLE();
        vm.prank(TREASURY);
        hook.grantRole(attestorRole, ATTESTOR);
    }

    // ─── helpers ────────────────────────────────────────────────────

    /// @dev Mint `amount` (18-dec wei) into `to`'s DEFAULT_NS via the MINTER_ROLE.
    function _mintTo(address to, uint256 amount) internal {
        vm.prank(TREASURY);
        token.mint(to, amount);
    }

    /// @dev Upsert a fresh ACTIVE KYA credential expiring at +30 days.
    function _activateKya(bytes32 credentialHash) internal {
        vm.prank(KYA_SYNC);
        kya.upsertCredential(credentialHash, KYA_SYNC, uint64(block.timestamp + 30 days));
    }

    /// @dev Mark a Travel-Rule attestation hash so legs >= $1k de minimis pass.
    function _attestTravelRule(bytes32 attestationHash) internal {
        vm.prank(ATTESTOR);
        hook.markTravelRuleAttested(attestationHash);
    }

    /// @dev Build + sign a complete MandateEnvelope with both principal and
    ///      agent ECDSA signatures over the EIP-712 typed data.
    function _signMandate(
        bytes32 mandateId,
        bytes32 nonce,
        bytes32 kyaCredentialHash,
        address[] memory assetAllowlist,
        uint256 maxPerTxUsd,
        uint256 maxTotalUsd,
        uint64 notBefore,
        uint64 expiresAt
    ) internal view returns (MandateEnvelope memory env) {
        env.principal = PRINCIPAL;
        env.agent = AGENT;
        env.kyaCredentialHash = kyaCredentialHash;
        env.assetAllowlist = assetAllowlist;
        env.maxPerTxUsd = maxPerTxUsd;
        env.maxTotalUsd = maxTotalUsd;
        env.notBefore = notBefore;
        env.expiresAt = expiresAt;
        env.mandateId = mandateId;
        env.nonce = nonce;

        bytes32 digest = _envelopeDigest(env);

        (uint8 v1, bytes32 r1, bytes32 s1) = vm.sign(PRINCIPAL_PK, digest);
        env.principalSignature = abi.encodePacked(r1, s1, v1);
        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(AGENT_PK, digest);
        env.agentSignature = abi.encodePacked(r2, s2, v2);
    }

    /// @dev Compute the EIP-712 digest the token uses for the envelope.
    ///      Mirrors the in-token logic exactly.
    function _envelopeDigest(MandateEnvelope memory env) internal view returns (bytes32) {
        bytes32 typeHash = keccak256(
            "MandateEnvelope(address principal,address agent,bytes32 kyaCredentialHash,"
            "address[] assetAllowlist,uint256 maxPerTxUsd,uint256 maxTotalUsd,"
            "uint64 notBefore,uint64 expiresAt,bytes32 mandateId,bytes32 nonce)"
        );
        // EIP-712 array of address — keccak256 of the abi-encoded array of elements
        bytes memory packed = new bytes(env.assetAllowlist.length * 32);
        for (uint256 i = 0; i < env.assetAllowlist.length; i++) {
            uint256 v = uint256(uint160(env.assetAllowlist[i]));
            assembly { mstore(add(add(packed, 32), mul(i, 32)), v) }
        }
        bytes32 assetsHash = keccak256(packed);

        bytes32 structHash = keccak256(abi.encode(
            typeHash,
            env.principal,
            env.agent,
            env.kyaCredentialHash,
            assetsHash,
            env.maxPerTxUsd,
            env.maxTotalUsd,
            env.notBefore,
            env.expiresAt,
            env.mandateId,
            env.nonce
        ));

        // Domain separator — must match EIP712(name="Rivier", version="1", chainId, verifyingContract=token)
        bytes32 domainTypeHash = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 domainSeparator = keccak256(abi.encode(
            domainTypeHash,
            keccak256(bytes("Rivier")),
            keccak256(bytes("1")),
            block.chainid,
            address(token)
        ));

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /// @dev Convenience builder: a simple, valid envelope authorising RIVR
    ///      transfers from PRINCIPAL up to maxPerTxUsd / maxTotalUsd, valid
    ///      now → +1 day. KYA hash equals the mandateId for test brevity
    ///      (any non-zero hash works as long as it's been activated).
    function _defaultMandate(
        bytes32 mandateId,
        uint256 maxPerTxUsd,
        uint256 maxTotalUsd
    ) internal view returns (MandateEnvelope memory) {
        address[] memory allow = new address[](1);
        allow[0] = address(token);
        return _signMandate(
            mandateId,
            keccak256(abi.encode(mandateId, "nonce")),
            mandateId, // reuse mandateId as kya credential hash
            allow,
            maxPerTxUsd,
            maxTotalUsd,
            uint64(block.timestamp),
            uint64(block.timestamp + 1 days)
        );
    }
}
