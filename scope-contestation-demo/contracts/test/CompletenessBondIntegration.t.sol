// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ScopeContestation}    from "../src/ScopeContestation.sol";
import {ResolutionCommitment} from "../src/ResolutionCommitment.sol";
import {Layer2PreCheck}       from "../src/Layer2PreCheck.sol";
import {MajorityClassifier}   from "../src/MajorityClassifier.sol";
import {NIProof, Vote}        from "../src/ScopeTypes.sol";
import {CompletenessBond, IScopeRegistry, ILayer2PreCheck} from "../src/CompletenessBond.sol";

/// @notice Layer-3 INTEGRATION suite - drives CompletenessBond against the REAL
///         four-guard stack (ScopeContestation + Layer2PreCheck + MajorityClassifier
///         + ResolutionCommitment), NO MockLayer2. This is the test the unit suite
///         can't be: MockLayer2 returns `separated` on command and fakes scopeRootOf,
///         so it proves the bond's branching but not the wiring. Here the slash verdict
///         comes from the real contest() and the existence check from the real L1
///         registry - so this is what actually proves:
///
///           1. the two-address wiring (Damon's e80fa5b integration fix): postBond
///              existence is checked against the L1 scope registry, not layer2.
///           2. a MATERIAL omission slashes through the real four guards.
///           3. an IMMATERIAL omission does not slash - the bond stands (Guarantee 1).
///           4. NO-LOCKOUT: a failed (non-separating) challenge does NOT lock the bond
///              against a later genuine material slash. This is the property that rested
///              on verifyScopeComplete pinning `a` - now exercised on the real contest().
///
///         Mirrors the proof-construction helpers from ContestFlow.t.sol (the 13/13
///         real-proof suite) so the coordinates are genuine absent-X materiality proofs.
contract CompletenessBondIntegrationTest is Test {
    ScopeContestation    scope;
    ResolutionCommitment res;
    Layer2PreCheck       pre;
    MajorityClassifier   clf;
    CompletenessBond     bond;

    uint8 constant WIN  = 1;
    uint8 constant LOSS = 2;
    uint8 constant DRAW = 3;

    function setUp() public {
        scope = new ScopeContestation();
        res   = new ResolutionCommitment();
        clf   = new MajorityClassifier();
        pre   = new Layer2PreCheck(scope, res);
        // the two-address binding (e80fa5b): existence against L1, verdict against L2
        bond  = new CompletenessBond(IScopeRegistry(address(scope)), ILayer2PreCheck(address(pre)));
        vm.deal(address(this), 100 ether);
    }

    receive() external payable {} // accept the slashed bounty as challenger

    // ───────────── proof helpers (mirror ContestFlow.t.sol / scope_ref.py) ─────────────
    function _leaf(bytes32 id) internal pure returns (bytes32) { return keccak256(abi.encodePacked(bytes1(0x00), id)); }
    function _node(bytes32 l, bytes32 r) internal pure returns (bytes32) { return keccak256(abi.encodePacked(bytes1(0x01), l, r)); }
    function _bind(bytes32 root, uint256 count) internal pure returns (bytes32) { return keccak256(abi.encode(root, count)); }
    function _id(string memory s) internal pure returns (bytes32) { return keccak256(bytes(s)); }

    function _layers(bytes32[] memory ids) internal pure returns (bytes32[][] memory layers) {
        uint256 n = ids.length; uint256 lv = 1; uint256 s = n;
        while (s > 1) { s = (s + 1) / 2; lv++; }
        layers = new bytes32[][](lv);
        bytes32[] memory level = new bytes32[](n);
        for (uint256 i = 0; i < n; i++) level[i] = _leaf(ids[i]);
        layers[0] = level; uint256 li = 1;
        while (level.length > 1) {
            uint256 m = level.length;
            bytes32[] memory nxt = new bytes32[]((m + 1) / 2);
            uint256 j = 0;
            for (uint256 i = 0; i < m; i += 2) { nxt[j] = (i + 1 < m) ? _node(level[i], level[i + 1]) : level[i]; j++; }
            layers[li] = nxt; li++; level = nxt;
        }
    }
    function _root(bytes32[] memory ids) internal pure returns (bytes32) { bytes32[][] memory L = _layers(ids); return L[L.length - 1][0]; }
    function _siblings(bytes32[] memory ids, uint256 idx) internal pure returns (bytes32[] memory) {
        bytes32[][] memory L = _layers(ids);
        bytes32[] memory tmp = new bytes32[](L.length); uint256 c = 0; uint256 pos = idx;
        for (uint256 lvl = 0; lvl + 1 < L.length; lvl++) {
            uint256 size = L[lvl].length;
            if (pos % 2 == 1) { tmp[c++] = L[lvl][pos - 1]; } else if (pos + 1 < size) { tmp[c++] = L[lvl][pos + 1]; }
            pos /= 2;
        }
        bytes32[] memory sibs = new bytes32[](c);
        for (uint256 i = 0; i < c; i++) sibs[i] = tmp[i];
        return sibs;
    }
    function _sort(bytes32[] memory a) internal pure returns (bytes32[] memory) {
        for (uint256 i = 1; i < a.length; i++) { bytes32 k = a[i]; uint256 j = i; while (j > 0 && uint256(a[j - 1]) > uint256(k)) { a[j] = a[j - 1]; j--; } a[j] = k; }
        return a;
    }
    function _makeNI(bytes32[] memory ids, bytes32 cc) internal pure returns (NIProof memory p) {
        uint256 n = ids.length; p.count = n;
        if (uint256(cc) < uint256(ids[0])) { p.caseId = 1; p.loCoord = ids[0]; p.sibsLo = _siblings(ids, 0); return p; }
        if (uint256(cc) > uint256(ids[n - 1])) { p.caseId = 2; p.hiCoord = ids[n - 1]; p.sibsHi = _siblings(ids, n - 1); return p; }
        for (uint256 i = 0; i + 1 < n; i++) {
            if (uint256(ids[i]) < uint256(cc) && uint256(cc) < uint256(ids[i + 1])) {
                p.caseId = 0; p.loCoord = ids[i]; p.hiCoord = ids[i + 1]; p.idxLo = i;
                p.sibsLo = _siblings(ids, i); p.sibsHi = _siblings(ids, i + 1); return p;
            }
        }
        revert("present");
    }
    function _market(string[4] memory names, uint8[4] memory opts) internal pure returns (bytes memory a, bytes32[] memory sortedIds) {
        Vote[] memory va = new Vote[](4); bytes32[] memory ids = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) { va[i] = Vote({sourceId: _id(names[i]), option: opts[i]}); ids[i] = _id(names[i]); }
        a = abi.encode(va); sortedIds = _sort(ids);
    }
    function _append(bytes memory a, bytes32 xId, uint8 opt) internal pure returns (bytes memory) {
        Vote[] memory va = abi.decode(a, (Vote[])); Vote[] memory vb = new Vote[](va.length + 1);
        for (uint256 i = 0; i < va.length; i++) vb[i] = va[i];
        vb[va.length] = Vote({sourceId: xId, option: opt}); return abi.encode(vb);
    }
    function _resRoot(bytes memory a) internal view returns (bytes32) { return res.computeResolutionRoot(abi.decode(a, (Vote[]))); }

    /// Commit a market-1 style 2WIN-2LOSS scope (UNCERTAIN base under 60% quorum) and
    /// return (scopeId, scopeRoot, a, sortedIds). Under this base: an absent X(DRAW) is
    /// immaterial (stays UNCERTAIN), an absent X(LOSS) is material (→ LOSS).
    function _commitTwoTwo(string memory tag) internal returns (bytes32 scopeId, bytes32 scopeRoot, bytes memory a, bytes32[] memory ids) {
        (a, ids) = _market(["t-WIN-A", "t-WIN-B", "t-LOSS-C", "t-LOSS-D"], [WIN, WIN, LOSS, LOSS]);
        scopeId   = _id(tag);
        scopeRoot = _bind(_root(ids), ids.length);
        pre.commitScope(scopeId, scopeRoot, abi.encode(uint256(4), uint256(6000)), clf);
        pre.commitResolution(scopeId, _resRoot(a));
    }

    // ───────────────────────────── TEST 1: wiring ─────────────────────────────────────
    /// postBond existence is checked against the REAL L1 registry (Damon's e80fa5b fix).
    function test_integration_postBond_realScopeRegistry() public {
        (bytes32 scopeId, bytes32 scopeRoot,,) = _commitTwoTwo("int-wiring");
        bytes32 bondId = bond.postBond{value: 1 ether}(scopeId, scopeRoot, 1 days);
        (uint256 amount,,,, bool slashed,) = bond.survival(bondId);
        assertEq(amount, 1 ether, "live bond carries the staked bounty");
        assertFalse(slashed, "fresh bond is not slashed");
        // an uncommitted scope must revert against the real registry (no mock to fake it)
        vm.expectRevert(bytes("scope not committed"));
        bond.postBond{value: 1 ether}(_id("never-committed"), scopeRoot, 1 days);
    }

    // ───────────────────────────── TEST 2: material slash ─────────────────────────────
    /// A material omission slashes through the real four guards; bounty pays the challenger.
    function test_integration_materialOmission_slashes_throughRealContest() public {
        (bytes32 scopeId, bytes32 scopeRoot, bytes memory a, bytes32[] memory ids) = _commitTwoTwo("int-material");
        bytes32 bondId = bond.postBond{value: 1 ether}(scopeId, scopeRoot, 1 days);

        bytes memory X = bytes("t-LOSS-Xmat"); bytes32 xId = keccak256(X);
        bytes memory b = _append(a, xId, LOSS); // 2WIN-3LOSS/5 = 60% LOSS → flips UNCERTAIN→LOSS
        bytes memory proof = abi.encode(a, b, abi.encode(_makeNI(ids, xId)));

        uint256 balBefore = address(this).balance;
        bond.challenge(bondId, X, proof);

        (uint256 amount,,, uint64 resolvedAt, bool slashed, bool challenged) = bond.survival(bondId);
        assertTrue(slashed,  "material omission must slash through real contest()");
        assertTrue(challenged, "challenged aliases slashed");
        assertGt(resolvedAt, 0, "slashed bond is resolved");
        assertEq(amount, 1 ether, "amount preserved as the historical bounty record");
        assertEq(address(this).balance, balBefore + 1 ether, "bounty pays the challenger");
    }

    // ───────────────────────────── TEST 3: immaterial stands ──────────────────────────
    /// An immaterial omission does NOT slash - the bond stands (sufficiency, Guarantee 1).
    function test_integration_immaterialOmission_doesNotSlash_bondStands() public {
        (bytes32 scopeId, bytes32 scopeRoot, bytes memory a, bytes32[] memory ids) = _commitTwoTwo("int-immaterial");
        bytes32 bondId = bond.postBond{value: 1 ether}(scopeId, scopeRoot, 1 days);

        bytes memory X = bytes("t-DRAW-Ximm"); bytes32 xId = keccak256(X);
        bytes memory b = _append(a, xId, DRAW); // 2WIN-2LOSS-1DRAW/5 = no 60% → stays UNCERTAIN
        bytes memory proof = abi.encode(a, b, abi.encode(_makeNI(ids, xId)));

        bond.challenge(bondId, X, proof);

        (,,, uint64 resolvedAt, bool slashed,) = bond.survival(bondId);
        assertFalse(slashed,   "immaterial omission must not slash");
        assertEq(resolvedAt, 0, "bond stands - still live");
    }

    // ───────────────────────────── TEST 4: NO-LOCKOUT ─────────────────────────────────
    /// THE property. A failed (non-separating) challenge does NOT lock the bond against a
    /// later genuine material slash - proven on the real contest(), not the mock. Step 1:
    /// an immaterial X(DRAW) → separated=false → bond stands. Step 2: a material X(LOSS) on
    /// the SAME standing bond → separated=true → slash. The prior failure didn't pre-burn it.
    function test_integration_noLockout_failedThenMaterial_realContest() public {
        (bytes32 scopeId, bytes32 scopeRoot, bytes memory a, bytes32[] memory ids) = _commitTwoTwo("int-nolockout");
        bytes32 bondId = bond.postBond{value: 1 ether}(scopeId, scopeRoot, 1 days);

        // 1. immaterial challenge - bond must stand
        bytes memory X1 = bytes("t-DRAW-X1"); bytes32 xId1 = keccak256(X1);
        bytes memory b1 = _append(a, xId1, DRAW);
        bond.challenge(bondId, X1, abi.encode(a, b1, abi.encode(_makeNI(ids, xId1))));
        (,,, uint64 r1, bool s1,) = bond.survival(bondId);
        assertFalse(s1, "non-separating challenge must not slash");
        assertEq(r1, 0, "bond still live after a failed challenge");

        // 2. material challenge on the SAME bond - must still slash (no lockout)
        bytes memory X2 = bytes("t-LOSS-X2"); bytes32 xId2 = keccak256(X2);
        bytes memory b2 = _append(a, xId2, LOSS);
        bond.challenge(bondId, X2, abi.encode(a, b2, abi.encode(_makeNI(ids, xId2))));
        (,,, uint64 r2, bool s2,) = bond.survival(bondId);
        assertTrue(s2, "a prior failed challenge MUST NOT lock out a genuine material slash");
        assertGt(r2, 0, "bond resolved by the material challenge");
    }
}
