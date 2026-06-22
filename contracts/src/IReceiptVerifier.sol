// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

/// @title IReceiptVerifier — the `valid` + `artifact_hash_matches` leg of the release gate.
/// @notice This is the ONE open design seam (see contracts/README.md "Open decisions"). It answers
///         the two off-chain receipt questions the escrow cannot answer by itself:
///           - `valid`               : the kind-30078 receipt is a genuine BIP-340/schnorr-signed
///                                     invinoveritas proof (id_integrity ∧ signature_valid ∧
///                                     issued_by_invinoveritas ∧ is_proof_event).
///           - `artifactHashMatches` : the receipt's artifact_hash == this job's expectArtifactHash.
///
///         CRITICAL (per the locked spec): `valid` does NOT include the artifact match, and the
///         escrow NEVER releases on `valid` alone. RecoveryEscrow ANDs BOTH of these with an
///         independent ON-CHAIN delivery check + an unspent nullifier. The verifier surfaces
///         evidence; the teeth are on-chain.
///
///         Implementations (pick one — the open call with Fede):
///           A) On-chain BIP-340 verification of the event signature   → fully trustless, no oracle
///              (purest fit for "nothing is a trusted oracle"; gas-heavy, needs a vetted secp256k1 lib).
///           B) Attestor EIP-712 signature from /verify-proof           → cheap; re-introduces trust in
///              the verifier key (acceptable v1 with a roadmap to A).
///           C) Optimistic challenge window                            → release after delay unless a
///              fraud proof is submitted; trust-minimized, adds latency.
interface IReceiptVerifier {
    /// @param expectArtifactHash  the job's bound spec hash H(job_id, target_wallet, output_address, asset_set).
    /// @param receiptProof        opaque, implementation-defined (raw event + sig, or an attestation, etc.).
    /// @return valid               receipt is a genuine signed proof (signature leg only).
    /// @return artifactHashMatches receipt.artifact_hash equals expectArtifactHash.
    function verify(bytes32 expectArtifactHash, bytes calldata receiptProof)
        external
        view
        returns (bool valid, bool artifactHashMatches);
}
