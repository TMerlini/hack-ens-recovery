// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IScopeContestation} from "./IScopeContestation.sol";
import {NIProof} from "./ScopeTypes.sol";

/// @title ScopeContestation — sorted-Merkle reference impl of the Layer 1 leg
/// @notice Faithful Solidity port of scope_ref.py option (b): cardinality is bound
///         INTO the scope root, `count` rides in the proof and is checked against the
///         committed root. A wrong `count` perturbs orientation → different recomputed
///         root → bind() mismatch → revert. Truncation/omission closed.
///
///   leaf(c)    = keccak256(0x00 ‖ c)            (domain-separated)
///   node(l,r)  = keccak256(0x01 ‖ l ‖ r)
///   odd node at a level is PROMOTED (carried up unchanged)
///   scopeRoot  = bind(root, N) = keccak256(abi.encode(root, N))
///
/// Orientation/promotion are derived by the verifier from (idx, count) ONLY — never
/// from prover-supplied flags. The prover supplies sibling hashes.
contract ScopeContestation is IScopeContestation {
    mapping(bytes32 => bytes32) private _roots;

    function commitScope(bytes32 scopeId, bytes32 scopeRoot) external {
        require(_roots[scopeId] == bytes32(0), "scope already committed");
        require(scopeRoot != bytes32(0), "empty scopeRoot");
        _roots[scopeId] = scopeRoot;
        emit ScopeCommitted(scopeId, scopeRoot);
    }

    function scopeRootOf(bytes32 scopeId) external view returns (bytes32) {
        return _roots[scopeId];
    }

    function verifyAbsence(bytes32 scopeRoot, bytes32 coordinateId, bytes calldata proof)
        external
        pure
        returns (bool)
    {
        NIProof memory p = abi.decode(proof, (NIProof));
        return _verifyNonInclusion(coordinateId, scopeRoot, p);
    }

    /// @notice DUAL of verifyAbsence — bind a witness set's base to the declared scope.
    ///         True iff `sourceIds` is EXACTLY the committed declared set: reconstructs
    ///         the cardinality-bound root from the ids and checks bind(root, |ids|) ==
    ///         scopeRoot. Because the root commits the full sorted leaf set, one check
    ///         proves membership ∧ completeness ∧ cardinality at once — no dropped,
    ///         added, or foreign coordinate. (Reference: sorts on-chain, O(n^2); a
    ///         production leg would take a sorted witness + verify the permutation.)
    function verifyScopeComplete(bytes32 scopeRoot, bytes32[] calldata sourceIds)
        external
        pure
        returns (bool)
    {
        uint256 n = sourceIds.length;
        if (n == 0) return false;
        bytes32[] memory ids = _sortMem(sourceIds);
        for (uint256 i = 1; i < n; i++) {
            if (uint256(ids[i]) <= uint256(ids[i - 1])) return false; // strictly increasing ⇒ no dupes
        }
        return _bind(_merkleRoot(ids), n) == scopeRoot;
    }

    // ───────────────────────── internals (mirror scope_ref.py) ─────────────────────────

    function _leaf(bytes32 c) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes1(0x00), c));
    }

    function _node(bytes32 l, bytes32 r) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes1(0x01), l, r));
    }

    function _bind(bytes32 root, uint256 count) private pure returns (bytes32) {
        return keccak256(abi.encode(root, count));
    }

    /// @dev Build the merkle root over sorted leaves (odd node promoted) — committer side.
    function _merkleRoot(bytes32[] memory ids) private pure returns (bytes32) {
        uint256 n = ids.length;
        bytes32[] memory level = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) level[i] = _leaf(ids[i]);
        while (level.length > 1) {
            uint256 m = level.length;
            bytes32[] memory nxt = new bytes32[]((m + 1) / 2);
            uint256 j = 0;
            for (uint256 i = 0; i < m; i += 2) {
                nxt[j] = (i + 1 < m) ? _node(level[i], level[i + 1]) : level[i]; // promote odd
                j++;
            }
            level = nxt;
        }
        return level[0];
    }

    /// @dev Ascending insertion sort over a copy (reference convenience; O(n^2)).
    function _sortMem(bytes32[] calldata a) private pure returns (bytes32[] memory out) {
        uint256 n = a.length;
        out = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) out[i] = a[i];
        for (uint256 i = 1; i < n; i++) {
            bytes32 k = out[i];
            uint256 j = i;
            while (j > 0 && uint256(out[j - 1]) > uint256(k)) {
                out[j] = out[j - 1];
                j--;
            }
            out[j] = k;
        }
    }

    /// @dev Climb the membership path; return (ok, recomputed root). Orientation and
    ///      promotion derived from (idx, count) only — identical rule across cases.
    function _climb(bytes32 leaf, uint256 idx, uint256 count, bytes32[] memory sibs)
        private
        pure
        returns (bool, bytes32)
    {
        bytes32 h = leaf;
        uint256 pos = idx;
        uint256 size = count;
        uint256 k = 0;
        while (size > 1) {
            if (pos % 2 == 1) {
                if (k >= sibs.length) return (false, bytes32(0));
                h = _node(sibs[k], h);
                k++;
            } else if (pos + 1 < size) {
                if (k >= sibs.length) return (false, bytes32(0));
                h = _node(h, sibs[k]);
                k++;
            } // else: promoted — consume no sibling
            pos /= 2;
            size = (size + 1) / 2;
        }
        if (k != sibs.length) return (false, bytes32(0)); // no leftover siblings
        return (true, h);
    }

    /// @dev `count` is taken from the proof, the Merkle root is recomputed from the
    ///      boundary membership path(s), and bind(root, count) MUST equal the committed
    ///      scopeRoot. Sound: a wrong count → different root → binding check fails.
    function _verifyNonInclusion(bytes32 c, bytes32 committedScopeRoot, NIProof memory p)
        private
        pure
        returns (bool)
    {
        bytes32 r;
        bool ok;
        if (p.caseId == 1) {
            // below min: c < leaf[0]
            if (!(uint256(c) < uint256(p.loCoord))) return false;
            (ok, r) = _climb(_leaf(p.loCoord), 0, p.count, p.sibsLo);
            if (!ok) return false;
        } else if (p.caseId == 2) {
            // above max: c > leaf[count-1]
            if (p.count == 0) return false;
            if (!(uint256(c) > uint256(p.hiCoord))) return false;
            (ok, r) = _climb(_leaf(p.hiCoord), p.count - 1, p.count, p.sibsHi);
            if (!ok) return false;
        } else {
            // interior straddle: leaf[idxLo] < c < leaf[idxLo+1], adjacent
            if (!(uint256(p.loCoord) < uint256(c) && uint256(c) < uint256(p.hiCoord))) return false;
            (bool okL, bytes32 rl) = _climb(_leaf(p.loCoord), p.idxLo, p.count, p.sibsLo);
            (bool okH, bytes32 rh) = _climb(_leaf(p.hiCoord), p.idxLo + 1, p.count, p.sibsHi);
            if (!okL || !okH || rl != rh) return false;
            r = rl;
        }
        return _bind(r, p.count) == committedScopeRoot;
    }
}
