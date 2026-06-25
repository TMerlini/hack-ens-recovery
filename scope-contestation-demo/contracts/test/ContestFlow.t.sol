// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ScopeContestation} from "../src/ScopeContestation.sol";
import {Layer2PreCheck} from "../src/Layer2PreCheck.sol";
import {MajorityClassifier} from "../src/MajorityClassifier.sol";
import {NIProof, Vote} from "../src/ScopeTypes.sol";

/// End-to-end proof that the Layer 1 verifyAbsence leg gates Jimmy's contest() flow:
///   - happy path: an absent, material X → contest returns separated = true
///   - Guarantee 4: the truncation attack (understate N, prove against a prefix) reverts
///   - soundness: no non-inclusion proof exists for a DECLARED coordinate
///   - non-material X → separated = false
contract ContestFlowTest is Test {
    ScopeContestation scope;
    Layer2PreCheck pre;
    MajorityClassifier clf;

    uint8 constant WIN = 1;
    uint8 constant LOSS = 2;

    function setUp() public {
        scope = new ScopeContestation();
        clf = new MajorityClassifier();
        pre = new Layer2PreCheck(scope);
    }

    // ───────────────────────── tree helpers (mirror scope_ref.py) ─────────────────────────

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
        uint256 n = ids.length;
        uint256 lv = 1;
        uint256 s = n;
        while (s > 1) { s = (s + 1) / 2; lv++; }
        layers = new bytes32[][](lv);
        bytes32[] memory level = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) level[i] = _leaf(ids[i]);
        layers[0] = level;
        uint256 li = 1;
        while (level.length > 1) {
            uint256 m = level.length;
            bytes32[] memory nxt = new bytes32[]((m + 1) / 2);
            uint256 j = 0;
            for (uint256 i = 0; i < m; i += 2) {
                nxt[j] = (i + 1 < m) ? _node(level[i], level[i + 1]) : level[i]; // promote odd
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
            if (pos % 2 == 1) {
                tmp[c++] = L[lvl][pos - 1];
            } else if (pos + 1 < size) {
                tmp[c++] = L[lvl][pos + 1];
            }
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

    /// mirror make_non_inclusion: build a proof that `cc` is absent from sorted `ids`.
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
        revert("present"); // cc is in the set — no non-inclusion proof exists (soundness)
    }

    // ───────────────────────── fixtures ─────────────────────────

    function _id(string memory s) internal pure returns (bytes32) {
        return keccak256(bytes(s));
    }

    /// declared sources (votes) + their sorted id set; returns (a, sortedDeclaredIds)
    function _market(string[4] memory names, uint8[4] memory opts)
        internal
        pure
        returns (bytes memory a, bytes32[] memory sortedIds)
    {
        Vote[] memory va = new Vote[](4);
        bytes32[] memory ids = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) {
            va[i] = Vote({sourceId: _id(names[i]), option: opts[i]});
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

    // ───────────────────────── tests ─────────────────────────

    /// Happy path: a is a 2–2 tie (NO_QUORUM); adding absent X(LOSS) makes LOSS clear
    /// quorum → w(a) != w(b) → X material → separated = true. The full contest() path
    /// runs: verifyAbsence (our leg) → isolation → classify.
    function test_contest_materialAbsentX_separates() public {
        (bytes memory a, bytes32[] memory ids) =
            _market(["m1-WIN-A", "m1-WIN-B", "m1-LOSS-C", "m1-LOSS-D"], [WIN, WIN, LOSS, LOSS]);
        bytes32 scopeId = _id("market-1");
        bytes32 scopeRoot = _bind(_root(ids), ids.length);
        bytes memory params = abi.encode(uint256(4), uint256(6000)); // minSamples=4, quorum 60%
        pre.commitScope(scopeId, scopeRoot, params, clf);

        bytes memory X = bytes("m1-LOSS-X");
        bytes32 xId = keccak256(X);
        bytes memory b = _append(a, xId, LOSS);
        bytes memory niProof = abi.encode(_makeNI(ids, xId));
        bytes memory proof = abi.encode(a, b, niProof);

        bool separated = pre.contest(scopeId, X, proof);
        assertTrue(separated, "absent X that flips the verdict must be material");
    }

    /// Guarantee 4: the truncation attack. Try to nominate a DECLARED coordinate by
    /// understating N and proving non-inclusion against a prefix root. The binding
    /// bind(root(prefix), N-1) != bind(root(full), N) makes verifyAbsence reject.
    function test_verifyAbsence_truncationAttack_rejected() public {
        (, bytes32[] memory ids) =
            _market(["m1-WIN-A", "m1-WIN-B", "m1-LOSS-C", "m1-LOSS-D"], [WIN, WIN, LOSS, LOSS]);
        bytes32 scopeRoot = _bind(_root(ids), ids.length); // committed over the FULL 4

        // attacker drops one DECLARED coord and proves non-inclusion over the other 3
        bytes32 victim = ids[1]; // a genuinely declared coordinate
        bytes32[] memory prefix = new bytes32[](3);
        uint256 j = 0;
        for (uint256 i = 0; i < 4; i++) {
            if (ids[i] != victim) prefix[j++] = ids[i];
        }
        NIProof memory atk = _makeNI(prefix, victim); // count = 3, prefix root
        bytes memory atkProof = abi.encode(atk);

        // bind(prefixRoot, 3) != bind(fullRoot, 4) → leg rejects (no revert needed; returns false)
        bool absent = scope.verifyAbsence(scopeRoot, victim, atkProof);
        assertFalse(absent, "truncated/understated-N proof must not pass verifyAbsence");
    }

    /// Soundness: a non-inclusion proof simply does not exist for a declared coordinate
    /// when you DON'T cheat the count (the prover helper cannot construct one).
    function test_makeNI_declaredCoordinate_hasNoProof() public {
        (, bytes32[] memory ids) =
            _market(["m1-WIN-A", "m1-WIN-B", "m1-LOSS-C", "m1-LOSS-D"], [WIN, WIN, LOSS, LOSS]);
        vm.expectRevert(bytes("present"));
        this.exposed_makeNI(ids, ids[2]);
    }

    function exposed_makeNI(bytes32[] memory ids, bytes32 cc) external pure returns (NIProof memory) {
        return _makeNI(ids, cc);
    }

    /// Non-material X: a already has a decisive WIN; adding absent X(LOSS) keeps WIN
    /// above quorum → w(a) == w(b) → separated = false. contest() still runs fully.
    function test_contest_nonMaterialAbsentX_notSeparated() public {
        (bytes memory a, bytes32[] memory ids) =
            _market(["m3-WIN-A", "m3-WIN-B", "m3-WIN-C", "m3-LOSS-D"], [WIN, WIN, WIN, LOSS]);
        bytes32 scopeId = _id("market-3");
        bytes32 scopeRoot = _bind(_root(ids), ids.length);
        bytes memory params = abi.encode(uint256(4), uint256(6000)); // 60%
        pre.commitScope(scopeId, scopeRoot, params, clf);

        bytes memory X = bytes("m3-LOSS-X");
        bytes32 xId = keccak256(X);
        bytes memory b = _append(a, xId, LOSS); // WIN 3/5 = 60% still clears
        bytes memory niProof = abi.encode(_makeNI(ids, xId));
        bytes memory proof = abi.encode(a, b, niProof);

        bool separated = pre.contest(scopeId, X, proof);
        assertFalse(separated, "absent X that does not change the verdict is not material");
    }

    /// Isolation guard: a witness pair differing on MORE than X is rejected.
    function test_contest_isolationViolation_reverts() public {
        (bytes memory a, bytes32[] memory ids) =
            _market(["m1-WIN-A", "m1-WIN-B", "m1-LOSS-C", "m1-LOSS-D"], [WIN, WIN, LOSS, LOSS]);
        bytes32 scopeId = _id("market-iso");
        bytes32 scopeRoot = _bind(_root(ids), ids.length);
        bytes memory params = abi.encode(uint256(4), uint256(6000));
        pre.commitScope(scopeId, scopeRoot, params, clf);

        bytes memory X = bytes("m1-LOSS-X");
        bytes32 xId = keccak256(X);
        // tamper: flip a declared vote in b as well as adding X (differs on >1 coord)
        Vote[] memory vb = new Vote[](5);
        Vote[] memory va = abi.decode(a, (Vote[]));
        for (uint256 i = 0; i < 4; i++) vb[i] = va[i];
        vb[0].option = LOSS; // tamper a declared coordinate
        vb[4] = Vote({sourceId: xId, option: LOSS});
        bytes memory b = abi.encode(vb);
        bytes memory proof = abi.encode(a, b, abi.encode(_makeNI(ids, xId)));

        vm.expectRevert(bytes("isolation"));
        pre.contest(scopeId, X, proof);
    }

    /// Adversarial `a` #1 (Fede): contester DROPS a declared source from `a` to compute
    /// w over a truncated base. verifyScopeComplete reconstructs bind(root(a), |a|) and it
    /// no longer matches the committed scopeRoot → reverts.
    function test_contest_adversarialA_droppedSource_reverts() public {
        (bytes memory aFull, bytes32[] memory ids) =
            _market(["m1-WIN-A", "m1-WIN-B", "m1-LOSS-C", "m1-LOSS-D"], [WIN, WIN, LOSS, LOSS]);
        bytes32 scopeId = _id("market-drop");
        bytes32 scopeRoot = _bind(_root(ids), ids.length); // committed over the full 4
        pre.commitScope(scopeId, scopeRoot, abi.encode(uint256(3), uint256(6000)), clf);

        // a' = only 3 of the 4 declared sources
        Vote[] memory vfull = abi.decode(aFull, (Vote[]));
        Vote[] memory v3 = new Vote[](3);
        for (uint256 i = 0; i < 3; i++) v3[i] = vfull[i];
        bytes memory a = abi.encode(v3);

        bytes memory X = bytes("m1-LOSS-X");
        bytes32 xId = keccak256(X);
        bytes memory b = _append(a, xId, LOSS);
        bytes memory proof = abi.encode(a, b, abi.encode(_makeNI(ids, xId)));

        vm.expectRevert(bytes("scope incomplete"));
        pre.contest(scopeId, X, proof);
    }

    /// Adversarial `a` #2 (Fede): contester swaps a declared source for a FOREIGN id not in
    /// scope. Same cardinality, different leaf set → reconstructed root ≠ committed → reverts.
    function test_contest_adversarialA_foreignSource_reverts() public {
        (bytes memory aFull, bytes32[] memory ids) =
            _market(["m1-WIN-A", "m1-WIN-B", "m1-LOSS-C", "m1-LOSS-D"], [WIN, WIN, LOSS, LOSS]);
        bytes32 scopeId = _id("market-foreign");
        bytes32 scopeRoot = _bind(_root(ids), ids.length);
        pre.commitScope(scopeId, scopeRoot, abi.encode(uint256(4), uint256(6000)), clf);

        // a' = 4 votes but one declared source replaced by a foreign id
        Vote[] memory va = abi.decode(aFull, (Vote[]));
        va[2] = Vote({sourceId: _id("m1-FOREIGN"), option: LOSS});
        bytes memory a = abi.encode(va);

        bytes memory X = bytes("m1-LOSS-X");
        bytes32 xId = keccak256(X);
        bytes memory b = _append(a, xId, LOSS);
        bytes memory proof = abi.encode(a, b, abi.encode(_makeNI(ids, xId)));

        vm.expectRevert(bytes("scope incomplete"));
        pre.contest(scopeId, X, proof);
    }
}
