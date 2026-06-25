// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @notice Sorted-Merkle non-inclusion proof for the Layer 1 verifyAbsence leg.
///         Mirrors scope_ref.py (verify_non_inclusion_b). Orientation/promotion are
///         derived by the verifier from (idx, count) ONLY — never from prover flags.
///         `count` rides inside the proof and is validated against the committed,
///         cardinality-bound scopeRoot (Guarantee 4), so the interface stays
///         scheme-agnostic while truncation/omission stays closed.
struct NIProof {
    uint8     caseId;   // 0 = interior straddle, 1 = below-min, 2 = above-max
    bytes32   loCoord;  // lower bracketing coordinate (cases 0,1)
    bytes32   hiCoord;  // upper bracketing coordinate (cases 0,2)
    uint256   idxLo;    // index of loCoord (interior); idxHi = idxLo + 1
    uint256   count;    // declared cardinality N — bound to scopeRoot
    bytes32[] sibsLo;   // membership siblings for loCoord
    bytes32[] sibsHi;   // membership siblings for hiCoord
}

/// @notice One source's reading in a witness-pair set. The Layer 2 reference
///         classifier (categorical/majority) tallies `option`; isolation is checked
///         on `sourceId`. `sourceId == keccak256(sourceDescriptor)` — the same 32-byte
///         identity the scope tree is built over and that contest() proves absent.
struct Vote {
    bytes32 sourceId;
    uint8   option;
}
