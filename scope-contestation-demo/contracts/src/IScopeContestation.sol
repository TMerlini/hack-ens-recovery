// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title IScopeContestation — Layer 1 absence-proof leg
/// @notice The abstract interface; the sorted-Merkle scheme is ONE reference impl
///         (pluggable — range-proofs / other accumulators can replace it without
///         touching the guarantee). The normative part: every omitted coordinate is
///         nominable and recomputable, a *declared* coordinate is NOT, and the
///         registry adjudicates nothing. Truncation/omission is closed by binding
///         cardinality into the scope root (Guarantee 4), so `count` is NOT a field
///         here — it is bound into `scopeRoot`.
interface IScopeContestation {
    event ScopeCommitted(bytes32 indexed scopeId, bytes32 scopeRoot);

    /// @notice Commit a market's declared input scope as a cardinality-bound root:
    ///         scopeRoot = bind(merkleRoot(sorted keccak256-id leaves), N).
    function commitScope(bytes32 scopeId, bytes32 scopeRoot) external;

    /// @notice The committed scope root for a market (provenance).
    function scopeRootOf(bytes32 scopeId) external view returns (bytes32);

    /// @notice Layer 1 absence guard. Called by ILayer2PreCheck.contest() as a
    ///         require() — reverts on failure, never encoded in `separated`.
    /// @param scopeRoot     the committed cardinality-bound root for the market
    /// @param coordinateId  the 32-byte coordinate identity X (= keccak256 of the
    ///                      nominated coordinate; contest() derives it ONCE and hands
    ///                      the same bytes to verifyAbsence and to classify — so the
    ///                      cross-layer "same coordinate" invariant is structural)
    /// @param proof         abi.encode(NIProof) — sorted-Merkle non-inclusion
    /// @return absent       true iff X is provably absent AND anchored to the full
    ///                      committed cardinality (no truncated/padded subtree)
    function verifyAbsence(bytes32 scopeRoot, bytes32 coordinateId, bytes calldata proof)
        external
        view
        returns (bool absent);
}
