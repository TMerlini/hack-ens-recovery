// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IScopeContestation} from "./IScopeContestation.sol";
import {IResolutionCommitment} from "./IResolutionCommitment.sol";
import {IScopeClassifier} from "./IScopeClassifier.sol";
import {Vote} from "./ScopeTypes.sol";

/// @title Layer2PreCheck — reference orchestrator for the contest() flow
///
/// @notice Owns market commitment (scopeRoot + resolutionRoot + classifier + params)
///         and runs contest() in the fixed guard order:
///
///           1. decode (a, b, verifyAbsenceProof)
///           2. coordinateHash = keccak256(nominatedCoordinate)  [derived ONCE]
///           3. GUARD — verifyAbsence       : X ∉ the declared cardinality-bound scope
///           4. GUARD — verifyScopeComplete : a's ids ARE exactly the declared set
///           5. GUARD — verifyValueFidelity : a's (id, value) pairs reproduce the
///                                            committed resolution readings
///           6. GUARD — isolation           : b = a + exactly X
///           7.          classify(a, b)     : w(a) vs w(b) → separated
///
///         All guards are require() — they revert, never encoded in `separated`.
///         coordinateHash is derived ONCE and passed to BOTH verifyAbsence and classify,
///         making the cross-layer coordinate-identity invariant structural.
///
///         Guard rationale:
///         - verifyAbsence      : X ∉ scope (Layer 1, Tiago)
///         - verifyScopeComplete: a is over the declared id-set (Fede/Tiago, 236b66a)
///         - verifyValueFidelity: a's values reproduce the actual resolution (this PR)
///         - isolation          : X, not some other difference, is the separator
///
///         Together they make the verdict "X was material to THE resolution" (S1),
///         not "X was material to some coordinate-complete `a` the contester chose."
///
/// @dev    commitScope() and commitResolution() are intentionally separate calls:
///         scopeRoot is committed at MARKET CREATION (before any reading exists);
///         resolutionRoot is committed at RESOLUTION TIME (after readings are final,
///         before the outcome is published). The two-phase commitment is what makes
///         the value-fidelity guard sound — a single-phase commitment can't carry both.

contract Layer2PreCheck {
    IScopeContestation   public immutable scope;
    IResolutionCommitment public immutable resolution;

    struct Market {
        bool               exists;
        bytes32            scopeRoot;
        bytes              params;
        IScopeClassifier   classifier;
    }

    mapping(bytes32 => Market) private _markets;

    event MarketCommitted(bytes32 indexed scopeId, bytes32 scopeRoot, address classifier);
    event Contested(
        bytes32 indexed scopeId,
        bytes32 indexed coordinateHash,
        bool    separated,
        bytes32 classificationDigest
    );

    constructor(IScopeContestation _scope, IResolutionCommitment _resolution) {
        scope      = _scope;
        resolution = _resolution;
    }

    // ─────────────────────────── phase 1: market creation ───────────────────────────

    /// @notice Pre-commit the market's declared scope + classifier + params.
    ///         MUST happen before any outcome is observable (pre-commit MUST).
    ///         scopeRoot = bind(merkleRoot(sorted id-leaves), N) — cardinality bound in.
    function commitScope(
        bytes32          scopeId,
        bytes32          scopeRoot,
        bytes calldata   params,
        IScopeClassifier classifier
    ) external {
        require(!_markets[scopeId].exists, "market exists");
        _markets[scopeId] = Market({
            exists:     true,
            scopeRoot:  scopeRoot,
            params:     params,
            classifier: classifier
        });
        scope.commitScope(scopeId, scopeRoot);
        emit MarketCommitted(scopeId, scopeRoot, address(classifier));
    }

    // ─────────────────────────── phase 2: resolution ────────────────────────────────

    /// @notice Commit the resolved readings for a market.
    ///         MUST be called after readings are final but BEFORE the outcome is
    ///         published (pre-outcome MUST from IResolutionCommitment).
    ///         Delegates to IResolutionCommitment — this orchestrator does not store
    ///         the root directly; it queries resolution.resolutionRootOf() at contest
    ///         time so the value-fidelity guard always uses the committed value.
    function commitResolution(bytes32 scopeId, bytes32 resolutionRoot) external {
        require(_markets[scopeId].exists, "no market");
        resolution.commitResolution(scopeId, resolutionRoot);
    }

    // ─────────────────────────── phase 3: contestation ──────────────────────────────

    /// @notice Contest that an omitted coordinate X was material to THE resolution.
    ///
    /// @param scopeId             the market identifier
    /// @param nominatedCoordinate the raw coordinate descriptor X (pre-image of coordinateHash)
    /// @param proof               abi.encode(bytes a, bytes b, bytes verifyAbsenceProof)
    ///
    /// @return separated  true = X is material (w(a) != w(b)); false = X is not material
    function contest(
        bytes32        scopeId,
        bytes calldata nominatedCoordinate,
        bytes calldata proof
    ) external returns (bool separated) {
        Market memory m = _markets[scopeId];
        require(m.exists, "no market");

        (bytes memory a, bytes memory b, bytes memory verifyAbsenceProof) =
            abi.decode(proof, (bytes, bytes, bytes));

        // Derive coordinateHash ONCE — passed to both verifyAbsence and classify so
        // the cross-layer "same coordinate" invariant is structural, not a convention.
        bytes32 coordinateHash = keccak256(nominatedCoordinate);

        // GUARD 1 — verifyAbsence: X is absent from the committed cardinality-bound scope.
        require(
            scope.verifyAbsence(m.scopeRoot, coordinateHash, verifyAbsenceProof),
            "verifyAbsence: present or unanchored"
        );

        // GUARD 2 — verifyScopeComplete: a's sourceIds ARE exactly the declared set
        // (membership ∧ completeness ∧ cardinality). Closes the coordinate half of the
        // adversarial-`a` gap (Fede / Tiago, 236b66a).
        require(
            scope.verifyScopeComplete(m.scopeRoot, _sourceIds(a)),
            "scope incomplete"
        );

        // GUARD 3 — verifyValueFidelity: a's (sourceId, value) pairs reproduce the
        // committed resolution readings. Closes the value half of the adversarial-`a`
        // gap: a contester who passes guards 1–2 still cannot set adversarial values
        // on the declared coords without the committed resolutionRoot rejecting them.
        require(
            resolution.verifyValueFidelity(scopeId, a),
            "value fidelity: a does not reproduce the committed resolution"
        );

        // GUARD 4 — isolation: b = a + exactly X (no other coordinate differs).
        require(_isolated(a, b, coordinateHash), "isolation");

        // classify: run w(a) vs w(b) — the only thing that touches classification.
        bytes32 digest;
        (separated, digest) = m.classifier.classify(scopeId, coordinateHash, m.params, a, b);
        emit Contested(scopeId, coordinateHash, separated, digest);
    }

    // ─────────────────────────── internals ──────────────────────────────────────────

    /// @dev Reference isolation: b appends exactly one vote whose sourceId == X;
    ///      all declared votes in b match a exactly; X is not in a.
    function _isolated(bytes memory a, bytes memory b, bytes32 x) private pure returns (bool) {
        Vote[] memory va = abi.decode(a, (Vote[]));
        Vote[] memory vb = abi.decode(b, (Vote[]));
        if (vb.length != va.length + 1) return false;
        for (uint256 i = 0; i < va.length; i++) {
            if (vb[i].sourceId != va[i].sourceId || vb[i].option != va[i].option) return false;
            if (va[i].sourceId == x) return false; // X must not already be in a
        }
        return vb[va.length].sourceId == x;
    }

    /// @dev Extract sourceIds from a Vote[] encoding for the scope-completeness guard.
    function _sourceIds(bytes memory a) private pure returns (bytes32[] memory ids) {
        Vote[] memory va = abi.decode(a, (Vote[]));
        ids = new bytes32[](va.length);
        for (uint256 i = 0; i < va.length; i++) ids[i] = va[i].sourceId;
    }
}
