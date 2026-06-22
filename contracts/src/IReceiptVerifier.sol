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
///         DECIDED (Fede / babyblueviper1, 2026-06-22): impl **A — on-chain BIP-340**, and Fede owns it.
///           - `BIP340Verifier`: schnorr verify via the `ecrecover` trick (map `s·G = R + e·P` onto a
///             single ecrecover, ~3k gas, native precompile — no bespoke secp256k1 lib), the kind-30078
///             event id recomputed via the sha256 precompile, then `content.artifact_hash == expectArtifactHash`.
///           - **B (attestor EIP-712) REJECTED** — it makes the verifier key the release authority, which
///             re-introduces the exact trust this model deletes; shipping it in the flagship example would
///             undercut the category where a skeptic reads the code.
///           - Fallback is **C (optimistic challenge window)** — and its challenge path itself invokes the
///             A verifier on demand, so there is NO trusted key in any path.
///         An SDK helper packs `receiptProof` in the exact calldata layout this verifier expects, byte-aligned
///         with off-chain `verifyFullFlow()` (same anti-drift discipline as `normalizeSpec`).
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
