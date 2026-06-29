// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IResolutionCommitment} from "./IResolutionCommitment.sol";
import {Vote} from "./ScopeTypes.sol";

/// @title ResolutionCommitment — type-2 reference impl of the value-fidelity leg
///
/// @notice Closes the VALUE half of the adversarial-`a` gap for off-chain readings:
///         verifies that `a`'s (sourceId, value) pairs exactly reproduce the
///         resolution-time commitment stored on-chain.
///
///         Scheme (type-2 / off-chain):
///
///             leaf_i    = keccak256(abi.encode(sourceId_i, value_i))
///                         where leaves are taken in ascending-sourceId order
///             resolutionRoot = keccak256(abi.encode(sortedLeaves))
///
///         The resolution authority commits resolutionRoot via commitResolution()
///         BEFORE publishing the outcome. verifyValueFidelity recomputes the same
///         digest from `a` and requires it to equal the committed root.
///
///         For type-1 (chain-native readings), a separate impl recomputes values
///         directly from chain state — no resolutionRoot needed (Fede's offer).
///
/// @dev    On-chain sort is O(n²) insertion sort — adequate for the reference / demo;
///         a production impl takes a sorted-witness argument + verifies the permutation
///         (same advice as Tiago's verifyScopeComplete NatSpec). The permutation-check
///         trick: verify each (sourceId, value) leaf against a Merkle proof over the
///         committed root, which is O(log n) per leaf.
///
/// @notice Pre-outcome MUST (from IResolutionCommitment): resolutionRoot MUST be
///         committed before the outcome is observable. An observation-commitment
///         primitive (ERC-8281) carries this by anchoring the digest on-chain before
///         resolution — use it as the commitment vehicle for production deployments.

contract ResolutionCommitment is IResolutionCommitment {

    mapping(bytes32 => bytes32) private _roots;  // scopeId → resolutionRoot
    mapping(bytes32 => bool)    private _committed;

    // ─────────────────────────── IResolutionCommitment ───────────────────────────

    function commitResolution(bytes32 scopeId, bytes32 resolutionRoot) external {
        require(!_committed[scopeId], "resolution already committed");
        require(resolutionRoot != bytes32(0), "empty resolutionRoot");
        _roots[scopeId] = resolutionRoot;
        _committed[scopeId] = true;
        emit ResolutionCommitted(scopeId, resolutionRoot);
    }

    function resolutionRootOf(bytes32 scopeId) external view returns (bytes32) {
        return _roots[scopeId];
    }

    /// @notice Recompute resolutionRoot from `a`'s (sourceId, value) pairs and
    ///         require it to equal the committed root.
    ///         `a` is abi.encode(Vote[]) — the same encoding contest() receives.
    function verifyValueFidelity(bytes32 scopeId, bytes calldata a)
        external
        view
        returns (bool)
    {
        bytes32 committed = _roots[scopeId];
        if (committed == bytes32(0)) return false; // no resolution committed

        Vote[] memory va = abi.decode(a, (Vote[]));
        uint256 n = va.length;
        if (n == 0) return false;

        // Sort votes ascending on sourceId (insertion sort — O(n²) reference impl;
        // see NatSpec for production permutation-check alternative)
        Vote[] memory sorted = new Vote[](n);
        for (uint256 i = 0; i < n; i++) sorted[i] = va[i];
        for (uint256 i = 1; i < n; i++) {
            Vote memory key = sorted[i];
            uint256 j = i;
            while (j > 0 && uint256(sorted[j - 1].sourceId) > uint256(key.sourceId)) {
                sorted[j] = sorted[j - 1];
                j--;
            }
            sorted[j] = key;
        }

        // Build leaf array: leaf_i = keccak256(abi.encode(sourceId_i, value_i))
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            leaves[i] = keccak256(abi.encode(sorted[i].sourceId, sorted[i].option));
        }

        // resolutionRoot = keccak256(abi.encode(leaves))
        return keccak256(abi.encode(leaves)) == committed;
    }

    /// @inheritdoc IResolutionCommitment
    /// @notice GUARD 7 (type-2): X (the omitted coordinate) is in NO commitment by
    ///         definition, so there is nothing on-chain to recompute its value against.
    ///         Its authenticity is the orthogonal source-auth / zkTLS leg, kept separate
    ///         from value-fidelity (the two legs Damon kept orthogonal). Returns false so a
    ///         type-2 contest cannot pin X's value here — it must come through the source-auth
    ///         leg, not be conflated with the resolution commitment.
    function verifyCoordinateValue(bytes32, bytes32, bytes calldata)
        external
        pure
        returns (bool)
    {
        return false; // type-2: defer to the orthogonal source-auth leg
    }

    // ─────────────────────────── helper (for committer) ───────────────────────────

    /// @notice Compute the resolutionRoot for a set of (sourceId, value) pairs.
    ///         Off-chain equivalent — call this before commitResolution() to derive
    ///         the correct root from the resolved readings.
    ///         Exposed as a pure view so committers and test helpers can use it
    ///         without deploying off-chain tooling.
    function computeResolutionRoot(Vote[] calldata votes)
        external
        pure
        returns (bytes32)
    {
        return _computeRoot(votes);
    }

    function _computeRoot(Vote[] memory votes) private pure returns (bytes32) {
        uint256 n = votes.length;
        Vote[] memory sorted = new Vote[](n);
        for (uint256 i = 0; i < n; i++) sorted[i] = votes[i];
        for (uint256 i = 1; i < n; i++) {
            Vote memory key = sorted[i];
            uint256 j = i;
            while (j > 0 && uint256(sorted[j - 1].sourceId) > uint256(key.sourceId)) {
                sorted[j] = sorted[j - 1];
                j--;
            }
            sorted[j] = key;
        }
        bytes32[] memory leaves = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) {
            leaves[i] = keccak256(abi.encode(sorted[i].sourceId, sorted[i].option));
        }
        return keccak256(abi.encode(leaves));
    }
}
