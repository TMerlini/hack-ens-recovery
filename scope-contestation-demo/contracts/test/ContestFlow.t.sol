// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ScopeContestation}    from "../src/ScopeContestation.sol";
import {ResolutionCommitment} from "../src/ResolutionCommitment.sol";
import {Layer2PreCheck}       from "../src/Layer2PreCheck.sol";
import {MajorityClassifier}   from "../src/MajorityClassifier.sol";
import {NIProof, Vote}        from "../src/ScopeTypes.sol";

/// @notice End-to-end test suite for the full four-guard contest() flow:
///
///   verifyAbsence → verifyScopeComplete → verifyValueFidelity → isolation → classify
///
///   Tests 1–7 mirror Tiago's 236b66a suite (verifyAbsence + verifyScopeComplete legs).
///   Tests 8–9 cover the value-fidelity leg (this PR):
///
///   8. test_contest_valueFidelity_adversarialA_reverts
///      A coordinate-complete `a` with boundary-tuned VALUES (3-3-1 split) passes
///      guards 1 and 2 but is rejected by guard 3 — proves verifyScopeComplete alone
///      is insufficient and the value leg is load-bearing.
///
///   9. test_contest_valueFidelity_fullHappyPath_separates
///      A correctly committed resolution with a genuine absent X runs all four guards
///      and returns separated = true.
///
contract ContestFlowTest is Test {
    ScopeContestation    scope;
    ResolutionCommitment res;
    Layer2PreCheck       pre;
    MajorityClassifier   clf;

    uint8 constant WIN  = 1;
    uint8 constant DRAW = 3;
    uint8 constant LOSS = 2;

    function setUp() public {
        scope = new ScopeContestation();
        res   = new ResolutionCommitment();
        clf   = new MajorityClassifier();
        pre   = new Layer2PreCheck(scope, res);
    }

    // ───────────────────────── tree helpers (mirror scope_ref.py) ─────────────────────

    function _leaf(bytes32 id) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes1(0x00), id));
    }
    function _node(bytes32 l, bytes32 r) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes1(0x01), l, r));
    }
    function _bind(bytes32 root, uint256 count) internal pure returns (bytes32) {
        return keccak256(abi.encode(root, count));
    }

    function _layers(bytes32[] memory ids) internal pure returns (bytes32[][] memory layers) {
        uint256 n   = ids.length;
        uint256 lv  = 1;
        uint256 s   = n;
        while (s > 1) { s = (s + 1) / 2; lv++; }
        layers = new bytes32[][](lv);
        bytes32[] memory level = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) level[i] = _leaf(ids[i]);
        layers[0] = level;
        uint256 li = 1;
        while (level.length > 1) {
            uint256 m   = level.length;
            bytes32[] memory nxt = new bytes32[]((m + 1) / 2);
            uint256 j = 0;
            for (uint256 i = 0; i < m; i += 2) {
                nxt[j] = (i + 1 < m) ? _node(level[i], level[i + 1]) : level[i];
                j++;
            }
            layers[li] = nxt;
            li++;
            level = nxt;
        }
    }

    function _root(bytes32[] memory ids) internal pure returns (bytes32) {
        bytes32[][] memory L = _layers(ids);
        return L[L.length - 1][0];
    }

    function _siblings(bytes32[] memory ids, uint256 idx) internal pure returns (bytes32[] memory) {
        bytes32[][] memory L = _layers(ids);
        bytes32[] memory tmp = new bytes32[](L.length);
        uint256 c = 0;
        uint256 pos = idx;
        for (uint256 lvl = 0; lvl + 1 < L.length; lvl++) {
            uint256 size = L[lvl].length;
            if (pos % 2 == 1)          { tmp[c++] = L[lvl][pos - 1]; }
            else if (pos + 1 < size)   { tmp[c++] = L[lvl][pos + 1]; }
            pos /= 2;
        }
        bytes32[] memory sibs = new bytes32[](c);
        for (uint256 i = 0; i < c; i++) sibs[i] = tmp[i];
        return sibs;
    }

    function _sort(bytes32[] memory a) internal pure returns (bytes32[] memory) {
        for (uint256 i = 1; i < a.length; i++) {
            bytes32 k = a[i];
            uint256 j = i;
            while (j > 0 && uint256(a[j - 1]) > uint256(k)) { a[j] = a[j - 1]; j--; }
            a[j] = k;
        }
        return a;
    }

    function _makeNI(bytes32[] memory ids, bytes32 cc) internal pure returns (NIProof memory p) {
        uint256 n = ids.length;
        p.count = n;
        if (uint256(cc) < uint256(ids[0])) {
            p.caseId = 1; p.loCoord = ids[0]; p.sibsLo = _siblings(ids, 0);
            return p;
        }
        if (uint256(cc) > uint256(ids[n - 1])) {
            p.caseId = 2; p.hiCoord = ids[n - 1]; p.sibsHi = _siblings(ids, n - 1);
            return p;
        }
        for (uint256 i = 0; i + 1 < n; i++) {
            if (uint256(ids[i]) < uint256(cc) && uint256(cc) < uint256(ids[i + 1])) {
                p.caseId = 0; p.loCoord = ids[i]; p.hiCoord = ids[i + 1];
                p.idxLo = i; p.sibsLo = _siblings(ids, i); p.sibsHi = _siblings(ids, i + 1);
                return p;
            }
        }
        revert("present");
    }

    // ───────────────────────── fixtures ───────────────────────────────────────────────

    function _id(string memory s) internal pure returns (bytes32) {
        return keccak256(bytes(s));
    }

    function _market(string[4] memory names, uint8[4] memory opts)
        internal
        pure
        returns (bytes memory a, bytes32[] memory sortedIds)
    {
        Vote[] memory va = new Vote[](4);
        bytes32[] memory ids = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) {
            va[i]  = Vote({sourceId: _id(names[i]), option: opts[i]});
            ids[i] = _id(names[i]);
        }
        a = abi.encode(va);
        sortedIds = _sort(ids);
    }

    function _append(bytes memory a, bytes32 xId, uint8 opt) internal pure returns (bytes memory) {
        Vote[] memory va = abi.decode(a, (Vote[]));
        Vote[] memory vb = new Vote[](va.length + 1);
        for (uint256 i = 0; i < va.length; i++) vb[i] = va[i];
        vb[va.length] = Vote({sourceId: xId, option: opt});
        return abi.encode(vb);
    }

    /// Build a resolution root from a Vote[] encoding (mirrors ResolutionCommitment._computeRoot)
    function _makeResolutionRoot(bytes memory a) internal view returns (bytes32) {
        Vote[] memory va = abi.decode(a, (Vote[]));
        return res.computeResolutionRoot(va);
    }

    // ───────────────────────── TESTS 1–7: Tiago's existing suite ─────────────────────
    //
    // These are the 7 tests from 236b66a, adapted to the updated Layer2PreCheck
    // constructor (now takes an IResolutionCommitment too). Each test calls
    // pre.commitResolution() with the correct root so guard 3 passes, keeping the
    // focus of each test on the guard it was written to cover.

    function test_contest_materialAbsentX_separates() public {
        (bytes memory a, bytes32[] memory ids) =
            _market(["m1-WIN-A", "m1-WIN-B", "m1-LOSS-C", "m1-LOSS-D"], [WIN, WIN, LOSS, LOSS]);
        bytes32 scopeId   = _id("market-1");
        bytes32 scopeRoot = _bind(_root(ids), ids.length);
        bytes memory params = abi.encode(uint256(4), uint256(6000));
        pre.commitScope(scopeId, scopeRoot, params, clf);
        pre.commitResolution(scopeId, _makeResolutionRoot(a)); // guard 3 passes

        bytes memory X    = bytes("m1-LOSS-X");
        bytes32 xId       = keccak256(X);
        bytes memory b    = _append(a, xId, LOSS);
        bytes memory proof = abi.encode(a, b, abi.encode(_makeNI(ids, xId)));

        bool separated = pre.contest(scopeId, X, proof);
        assertTrue(separated, "absent X that flips the verdict must be material");
    }

    function test_verifyAbsence_truncationAttack_rejected() public {
        (, bytes32[] memory ids) =
            _market(["m1-WIN-A", "m1-WIN-B", "m1-LOSS-C", "m1-LOSS-D"], [WIN, WIN, LOSS, LOSS]);
        bytes32 scopeRoot = _bind(_root(ids), ids.length);

        bytes32 victim = ids[1];
        bytes32[] memory prefix = new bytes32[](3);
        uint256 j = 0;
        for (uint256 i = 0; i < 4; i++) {
            if (ids[i] != victim) prefix[j++] = ids[i];
        }
        NIProof memory atk = _makeNI(prefix, victim);
        bool absent = scope.verifyAbsence(scopeRoot, victim, abi.encode(atk));
        assertFalse(absent, "truncated/understated-N proof must not pass verifyAbsence");
    }

    function test_makeNI_declaredCoordinate_hasNoProof() public {
        (, bytes32[] memory ids) =
            _market(["m1-WIN-A", "m1-WIN-B", "m1-LOSS-C", "m1-LOSS-D"], [WIN, WIN, LOSS, LOSS]);
        vm.expectRevert(bytes("present"));
        this.exposed_makeNI(ids, ids[2]);
    }

    function exposed_makeNI(bytes32[] memory ids, bytes32 cc) external pure returns (NIProof memory) {
        return _makeNI(ids, cc);
    }

    function test_contest_nonMaterialAbsentX_notSeparated() public {
        (bytes memory a, bytes32[] memory ids) =
            _market(["m3-WIN-A", "m3-WIN-B", "m3-WIN-C", "m3-LOSS-D"], [WIN, WIN, WIN, LOSS]);
        bytes32 scopeId   = _id("market-3");
        bytes32 scopeRoot = _bind(_root(ids), ids.length);
        bytes memory params = abi.encode(uint256(4), uint256(6000));
        pre.commitScope(scopeId, scopeRoot, params, clf);
        pre.commitResolution(scopeId, _makeResolutionRoot(a));

        bytes memory X = bytes("m3-LOSS-X");
        bytes32 xId   = keccak256(X);
        bytes memory b = _append(a, xId, LOSS);
        bytes memory proof = abi.encode(a, b, abi.encode(_makeNI(ids, xId)));

        bool separated = pre.contest(scopeId, X, proof);
        assertFalse(separated, "absent X that does not change the verdict is not material");
    }

    function test_contest_isolationViolation_reverts() public {
        (bytes memory a, bytes32[] memory ids) =
            _market(["m1-WIN-A", "m1-WIN-B", "m1-LOSS-C", "m1-LOSS-D"], [WIN, WIN, LOSS, LOSS]);
        bytes32 scopeId   = _id("market-iso");
        bytes32 scopeRoot = _bind(_root(ids), ids.length);
        bytes memory params = abi.encode(uint256(4), uint256(6000));
        pre.commitScope(scopeId, scopeRoot, params, clf);
        pre.commitResolution(scopeId, _makeResolutionRoot(a));

        bytes memory X  = bytes("m1-LOSS-X");
        bytes32 xId     = keccak256(X);
        Vote[] memory vb = new Vote[](5);
        Vote[] memory va = abi.decode(a, (Vote[]));
        for (uint256 i = 0; i < 4; i++) vb[i] = va[i];
        vb[0].option = LOSS; // tamper a declared coordinate
        vb[4] = Vote({sourceId: xId, option: LOSS});
        bytes memory proof = abi.encode(a, abi.encode(vb), abi.encode(_makeNI(ids, xId)));

        vm.expectRevert(bytes("isolation"));
        pre.contest(scopeId, X, proof);
    }

    function test_contest_droppedSource_reverts() public {
        (bytes memory a, bytes32[] memory ids) =
            _market(["m5-WIN-A", "m5-WIN-B", "m5-LOSS-C", "m5-LOSS-D"], [WIN, WIN, LOSS, LOSS]);
        bytes32 scopeId   = _id("market-5");
        bytes32 scopeRoot = _bind(_root(ids), ids.length);
        bytes memory params = abi.encode(uint256(4), uint256(6000));
        pre.commitScope(scopeId, scopeRoot, params, clf);
        pre.commitResolution(scopeId, _makeResolutionRoot(a));

        // a_bad: only 3 of 4 declared sources (dropped one)
        Vote[] memory va    = abi.decode(a, (Vote[]));
        Vote[] memory vBad  = new Vote[](3);
        for (uint256 i = 0; i < 3; i++) vBad[i] = va[i];
        bytes memory aBad   = abi.encode(vBad);

        bytes memory X  = bytes("m5-LOSS-X");
        bytes32 xId     = keccak256(X);
        bytes memory b  = _append(aBad, xId, LOSS);
        bytes memory proof = abi.encode(aBad, b, abi.encode(_makeNI(ids, xId)));

        vm.expectRevert(bytes("scope incomplete"));
        pre.contest(scopeId, X, proof);
    }

    function test_contest_foreignSource_reverts() public {
        (bytes memory a, bytes32[] memory ids) =
            _market(["m6-WIN-A", "m6-WIN-B", "m6-LOSS-C", "m6-LOSS-D"], [WIN, WIN, LOSS, LOSS]);
        bytes32 scopeId   = _id("market-6");
        bytes32 scopeRoot = _bind(_root(ids), ids.length);
        bytes memory params = abi.encode(uint256(4), uint256(6000));
        pre.commitScope(scopeId, scopeRoot, params, clf);
        pre.commitResolution(scopeId, _makeResolutionRoot(a));

        // a_bad: swap one declared source for a foreign one not in scopeRoot
        Vote[] memory va   = abi.decode(a, (Vote[]));
        Vote[] memory vBad = new Vote[](4);
        for (uint256 i = 0; i < 4; i++) vBad[i] = va[i];
        vBad[3].sourceId = _id("m6-FOREIGN-Z"); // not in tree
        bytes memory aBad = abi.encode(vBad);

        bytes memory X  = bytes("m6-LOSS-X");
        bytes32 xId     = keccak256(X);
        bytes memory b  = _append(aBad, xId, LOSS);
        bytes memory proof = abi.encode(aBad, b, abi.encode(_makeNI(ids, xId)));

        vm.expectRevert(bytes("scope incomplete"));
        pre.contest(scopeId, X, proof);
    }

    // ───────────────────────── TESTS 8–9: value-fidelity leg (this PR) ───────────────

    /// @notice Test 8 — THE key test for this PR.
    ///
    ///         Scenario: the real resolution is a robust 6–1 WIN majority. No single
    ///         absent X can flip it. But a contester ignores the real resolution and
    ///         fabricates a coordinate-complete `a` as a boundary-split 3–3–1 (the
    ///         construction from the review thread), where adding any X(WIN) tips the
    ///         result from UNCERTAIN to WIN.
    ///
    ///         This `a` passes guard 1 (verifyAbsence: X genuinely absent) and guard 2
    ///         (verifyScopeComplete: all 7 declared sourceIds present, cardinality matches).
    ///         Guard 3 (verifyValueFidelity) rejects it: the recomputed resolution root
    ///         of the fabricated values ≠ the committed root of the real readings.
    ///
    ///         Without this guard the gate returns separated = true despite the real
    ///         scope being complete — a false positive constructible for ANY undeclared X.

    function test_contest_valueFidelity_adversarialA_reverts() public {
        // Real resolution: robust WIN majority (6-1), scope is complete.
        // 7 declared sources, quorum 5000 bps (50%).
        string[7] memory names = ["vf-S1", "vf-S2", "vf-S3", "vf-S4", "vf-S5", "vf-S6", "vf-S7"];
        uint8[7]  memory opts  = [WIN, WIN, WIN, WIN, WIN, WIN, DRAW];

        Vote[] memory realVotes = new Vote[](7);
        bytes32[] memory ids    = new bytes32[](7);
        for (uint256 i = 0; i < 7; i++) {
            ids[i]        = _id(names[i]);
            realVotes[i]  = Vote({sourceId: ids[i], option: opts[i]});
        }
        ids = _sort(ids);

        bytes32 scopeId   = _id("market-vf");
        bytes32 scopeRoot = _bind(_root(ids), ids.length);
        bytes memory params = abi.encode(uint256(7), uint256(5000)); // minSamples=7, quorum=50%
        pre.commitScope(scopeId, scopeRoot, params, clf);

        // Commit the REAL resolution root (6 WIN, 1 DRAW — in sourceId order)
        bytes32 realRoot = res.computeResolutionRoot(realVotes);
        pre.commitResolution(scopeId, realRoot);

        // Contester fabricates a = boundary-split (3 WIN, 3 DRAW, 1 LOSS) using the
        // same 7 declared sourceIds. Passes guards 1 and 2. Fails guard 3.
        Vote[] memory fakeVotes = new Vote[](7);
        // Use the same sourceIds but adversarial values
        bytes32[] memory sortedIds = ids; // already sorted
        fakeVotes[0] = Vote({sourceId: sortedIds[0], option: WIN});
        fakeVotes[1] = Vote({sourceId: sortedIds[1], option: WIN});
        fakeVotes[2] = Vote({sourceId: sortedIds[2], option: WIN});
        fakeVotes[3] = Vote({sourceId: sortedIds[3], option: DRAW});
        fakeVotes[4] = Vote({sourceId: sortedIds[4], option: DRAW});
        fakeVotes[5] = Vote({sourceId: sortedIds[5], option: DRAW});
        fakeVotes[6] = Vote({sourceId: sortedIds[6], option: LOSS});
        bytes memory aFake = abi.encode(fakeVotes);

        bytes memory X   = bytes("vf-X-extra");
        bytes32 xId      = keccak256(X);
        bytes memory b   = _append(aFake, xId, WIN);
        bytes memory proof = abi.encode(aFake, b, abi.encode(_makeNI(ids, xId)));

        vm.expectRevert(bytes("value fidelity: a does not reproduce the committed resolution"));
        pre.contest(scopeId, X, proof);
    }

    /// @notice Test 9 — Happy path through all four guards with value-fidelity wired.
    ///
    ///         Scenario: the real resolution is a 3–3–1 split (UNCERTAIN). A genuine
    ///         absent X reporting WIN tips it to WIN. `a` is the actual committed
    ///         readings, so guard 3 passes, and separated = true is a sound verdict:
    ///         X was material to THE resolution, not to a contester-chosen base.

    function test_contest_valueFidelity_fullHappyPath_separates() public {
        // Real resolution: genuine 3-3-1 split (UNCERTAIN under 50% quorum).
        // 7 declared sources, quorum 5000 bps (50%).
        string[7] memory names = ["hp-S1", "hp-S2", "hp-S3", "hp-S4", "hp-S5", "hp-S6", "hp-S7"];
        uint8[7]  memory opts  = [WIN, WIN, WIN, DRAW, DRAW, DRAW, LOSS];

        Vote[] memory realVotes = new Vote[](7);
        bytes32[] memory ids    = new bytes32[](7);
        for (uint256 i = 0; i < 7; i++) {
            ids[i]       = _id(names[i]);
            realVotes[i] = Vote({sourceId: ids[i], option: opts[i]});
        }
        ids = _sort(ids);

        bytes32 scopeId   = _id("market-hp");
        bytes32 scopeRoot = _bind(_root(ids), ids.length);
        bytes memory params = abi.encode(uint256(7), uint256(5000));
        pre.commitScope(scopeId, scopeRoot, params, clf);

        // a is the honest base: the actual committed readings
        bytes memory a = abi.encode(realVotes);
        pre.commitResolution(scopeId, res.computeResolutionRoot(realVotes));

        bytes memory X  = bytes("hp-X-extra");
        bytes32 xId     = keccak256(X);
        bytes memory b  = _append(a, xId, WIN); // X(WIN) tips 4/8=50%≥50% → WIN
        bytes memory proof = abi.encode(a, b, abi.encode(_makeNI(ids, xId)));

        bool separated = pre.contest(scopeId, X, proof);
        assertTrue(separated, "X that changes the verdict from UNCERTAIN to WIN must be material");
    }
}
