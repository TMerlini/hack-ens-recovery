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

        // (a, delta) form: delta is the single contested coordinate X as one abi-encoded
        // Vote. b is reconstructed in-contract as a ++ [delta] — byte-identical to the old
        // passed-b (proven byte-for-byte in DeltaIsolationGuard7.t.sol), so the classify
        // digest is unchanged and conformance vectors stay green. Saves ~|a| calldata.
        (bytes memory a, bytes memory deltaEnc, bytes memory verifyAbsenceProof) =
            abi.decode(proof, (bytes, bytes, bytes));
        Vote memory delta = abi.decode(deltaEnc, (Vote));
        bytes memory b = abi.encode(_reconstructB(a, delta));

        // Derive coordinateHash ONCE — passed to both verifyAbsence and classify so
        // the cross-layer "same coordinate" invariant is structural, not a convention.
        bytes32 coordinateHash = keccak256(nominatedCoordinate);

        // The reconstructed coordinate MUST be the one proven absent, or a contester could
        // isolate a different coordinate than the one verifyAbsence cleared.
        require(delta.sourceId == coordinateHash, "delta != nominated coordinate");

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

        // GUARD 7 — adversarial-X: X's value must reproduce its real committed reading.
        // X is not in `a`, so it cannot ride guard 3; pin it independently on the delta.
        // type-1 recomputes from the pinned chain source; type-2 returns false (X-value is
        // the orthogonal source-auth leg, deferred). delta.option is abi.encode'd as the value.
        require(
            resolution.verifyCoordinateValue(scopeId, delta.sourceId, abi.encode(delta.option)),
            "guard 7: X value does not reproduce committed reading"
        );

        // GUARD 4 — isolation collapses to X ∉ a: b is reconstructed as a ++ [X] in
        // contract, so length (n+1) and positional equality hold BY CONSTRUCTION. The only
        // structural fact left is that X was not already in a.
        require(_xNotInA(a, coordinateHash), "isolation: X already in a");

        // classify: run w(a) vs w(b) — the only thing that touches classification.
        bytes32 digest;
        (separated, digest) = m.classifier.classify(scopeId, coordinateHash, m.params, a, b);
        emit Contested(scopeId, coordinateHash, separated, digest);
    }

    // ─────────────────────────── internals ──────────────────────────────────────────

    /// @dev Reference isolation: b appends exactly one vote whose sourceId == X;
    ///      all declared votes in b match a exactly; X is not in a.
    /// @dev Reconstruct b = a ++ [delta]. Byte-identical to the canonical contester
    ///      append-then-encode path (proven in DeltaIsolationGuard7.t.sol), so
    ///      abi.encode(b) feeds classify with an unchanged digest.
    function _reconstructB(bytes memory a, Vote memory delta)
        private pure returns (Vote[] memory b)
    {
        Vote[] memory va = abi.decode(a, (Vote[]));
        b = new Vote[](va.length + 1);
        for (uint256 i = 0; i < va.length; i++) b[i] = va[i];
        b[va.length] = delta;
    }

    /// @dev The only structural isolation fact left once b is reconstructed: X not in a.
    function _xNotInA(bytes memory a, bytes32 x) private pure returns (bool) {
        Vote[] memory va = abi.decode(a, (Vote[]));
        for (uint256 i = 0; i < va.length; i++) {
            if (va[i].sourceId == x) return false;
        }
        return true;
    }

    /// @dev Extract sourceIds from a Vote[] encoding for the scope-completeness guard.
    function _sourceIds(bytes memory a) private pure returns (bytes32[] memory ids) {
        Vote[] memory va = abi.decode(a, (Vote[]));
        ids = new bytes32[](va.length);
        for (uint256 i = 0; i < va.length; i++) ids[i] = va[i].sourceId;
    }
}
