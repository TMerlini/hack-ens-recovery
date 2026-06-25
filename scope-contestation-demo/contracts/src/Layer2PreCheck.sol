// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IScopeContestation} from "./IScopeContestation.sol";
import {IScopeClassifier} from "./IScopeClassifier.sol";
import {Vote} from "./ScopeTypes.sol";

/// @title Layer2PreCheck — reference orchestrator for the contest() flow
/// @notice Owns market commitment (scopeRoot + classifier params) and runs contest()
///         in the order Jimmy's spec fixes:
///           1. decode (a, b, verifyAbsenceProof)
///           2. coordinateHash = keccak256(nominatedCoordinate)
///           3. GUARD — Layer 1 verifyAbsence (OUR leg): X absent from the
///              cardinality-bound scopeRoot
///           4. GUARD — isolation: b = a + exactly X
///           5. hand off (a, b, coordinateHash, params) → classifier.classify()
///         All guards are require() — they revert, never encoded in `separated`.
///         coordinateHash is derived ONCE and passed to BOTH verifyAbsence and
///         classify, so the cross-layer coordinate-identity invariant is structural.
contract Layer2PreCheck {
    IScopeContestation public immutable scope;

    struct Market {
        bool exists;
        bytes32 scopeRoot;
        bytes params;
        IScopeClassifier classifier;
    }

    mapping(bytes32 => Market) private _markets;

    event MarketCommitted(bytes32 indexed scopeId, bytes32 scopeRoot, address classifier);
    event Contested(bytes32 indexed scopeId, bytes32 indexed coordinateHash, bool separated, bytes32 classificationDigest);

    constructor(IScopeContestation _scope) {
        scope = _scope;
    }

    /// @notice Pre-commit the market: declared scope (cardinality-bound) + the
    ///         classifier and its params (= the full definition of w for this market).
    ///         MUST happen before the outcome is observable (Jimmy's pre-commit MUST).
    function commitScope(bytes32 scopeId, bytes32 scopeRoot, bytes calldata params, IScopeClassifier classifier)
        external
    {
        require(!_markets[scopeId].exists, "market exists");
        _markets[scopeId] = Market({exists: true, scopeRoot: scopeRoot, params: params, classifier: classifier});
        scope.commitScope(scopeId, scopeRoot);
        emit MarketCommitted(scopeId, scopeRoot, address(classifier));
    }

    /// @notice Contest that an omitted coordinate X was material.
    /// @param nominatedCoordinate the raw coordinate descriptor X (pre-image)
    /// @param proof abi.encode(bytes a, bytes b, bytes verifyAbsenceProof)
    /// @return separated true = X is material (w(a) != w(b))
    function contest(bytes32 scopeId, bytes calldata nominatedCoordinate, bytes calldata proof)
        external
        returns (bool separated)
    {
        Market memory m = _markets[scopeId];
        require(m.exists, "no market");

        (bytes memory a, bytes memory b, bytes memory verifyAbsenceProof) =
            abi.decode(proof, (bytes, bytes, bytes));

        bytes32 coordinateHash = keccak256(nominatedCoordinate);

        // GUARD — Layer 1 (our leg): X is absent from the cardinality-bound scope.
        require(
            scope.verifyAbsence(m.scopeRoot, coordinateHash, verifyAbsenceProof),
            "verifyAbsence: present or unanchored"
        );

        // GUARD — scope-completeness (dual of verifyAbsence): a's base IS exactly the
        // committed declared set, so w(a) is computed over the declared scope, not a
        // contester-chosen base. Closes the adversarial-`a` gap (Fede, 2026-06-25).
        require(scope.verifyScopeComplete(m.scopeRoot, _sourceIds(a)), "scope incomplete");

        // GUARD — isolation: b adds exactly X over a, agreeing on every declared coord.
        require(_isolated(a, b, coordinateHash), "isolation");

        bytes32 digest;
        (separated, digest) = m.classifier.classify(scopeId, coordinateHash, m.params, a, b);
        emit Contested(scopeId, coordinateHash, separated, digest);
    }

    /// @dev Reference isolation: a is the prefix of b, b appends exactly one vote
    ///      whose sourceId == X, and X is not among the declared (a) sources.
    function _isolated(bytes memory a, bytes memory b, bytes32 x) private pure returns (bool) {
        Vote[] memory va = abi.decode(a, (Vote[]));
        Vote[] memory vb = abi.decode(b, (Vote[]));
        if (vb.length != va.length + 1) return false;
        for (uint256 i = 0; i < va.length; i++) {
            if (vb[i].sourceId != va[i].sourceId || vb[i].option != va[i].option) return false;
            if (va[i].sourceId == x) return false; // X must be undeclared
        }
        return vb[va.length].sourceId == x;
    }

    /// @dev Extract the witness set's source identities for the scope-completeness guard.
    function _sourceIds(bytes memory a) private pure returns (bytes32[] memory ids) {
        Vote[] memory va = abi.decode(a, (Vote[]));
        ids = new bytes32[](va.length);
        for (uint256 i = 0; i < va.length; i++) ids[i] = va[i].sourceId;
    }
}
