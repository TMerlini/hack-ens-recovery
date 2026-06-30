// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {ScopeContestation}     from "../src/ScopeContestation.sol";
import {ChainNativeResolution} from "../src/ChainNativeResolution.sol";
import {ResolutionCommitment}  from "../src/ResolutionCommitment.sol";
import {Layer2PreCheck}        from "../src/Layer2PreCheck.sol";
import {MajorityClassifier}    from "../src/MajorityClassifier.sol";
import {IChainReadings}        from "../src/IChainReadings.sol";
import {NIProof, Vote}         from "../src/ScopeTypes.sol";
import {CompletenessBond, IScopeRegistry, ILayer2PreCheck} from "../src/CompletenessBond.sol";

/// @notice A historical-addressable on-chain readings source (test double), mirrors the one in
///         ChainNativeValueFidelity.t.sol. Values stored per (sourceId, block) so valueAt() is
///         deterministic and guard 7 can recompute against it.
contract MockChainReadings is IChainReadings {
    mapping(bytes32 => mapping(uint256 => uint8)) private _v;
    function setValue(bytes32 sourceId, uint256 blockNumber, uint8 option) external {
        _v[sourceId][blockNumber] = option;
    }
    function valueAt(bytes32 sourceId, uint256 blockNumber) external view returns (uint8) {
        return _v[sourceId][blockNumber];
    }
}

/// @notice Layer-3 INTEGRATION suite — drives CompletenessBond against the REAL four-guard stack
///         (ScopeContestation + Layer2PreCheck + MajorityClassifier + a real IResolutionCommitment),
///         NO MockLayer2. This is the test the 15/15 unit suite can't be: MockLayer2 returns
///         `separated` on command and fakes scopeRootOf, so it proves the bond's branching but not
///         the wiring. Here the slash verdict comes from the real contest() and the existence check
///         from the real L1 registry.
///
///         POST-#8 NOTE (type-1 reseat + type-2 deferral, A+B per Fede):
///         Under the (a, delta) + guard-7 wire, guard 7 recomputes X's value on type-1 and DEFERS
///         on type-2 (returns false → revert). The bond's challenge → contest path inherits that.
///         The bond mechanics (postBond/slash/bounty/no-lockout) consume the `separated` bool and are
///         orthogonal to HOW it was derived — so the four bond properties are proven through a REAL
///         type-1 contest() where in-contract separation is exercisable (A). The residual type-2
///         question — that a deferred (reverting) bond challenge does not lock the committer or
///         strand the challenger — is pinned by a clean-deferral test (B). no-lockout therefore holds
///         for BOTH types: type-1 by real separation, type-2 by non-locking deferral. The richer
///         "type-2 bond parks pending source-auth" behavior rides the source-auth leg, not this PR
///         (same defer drawn on #8).
contract CompletenessBondIntegrationTest is Test {
    ScopeContestation     scope;
    ChainNativeResolution res;     // type-1 resolution (A tests)
    Layer2PreCheck        pre;
    MajorityClassifier    clf;
    MockChainReadings     chain;
    CompletenessBond      bond;
    uint256               PIN;

    uint8 constant WIN  = 1;
    uint8 constant LOSS = 2;
    uint8 constant DRAW = 3;

    function setUp() public {
        scope = new ScopeContestation();
        res   = new ChainNativeResolution();
        clf   = new MajorityClassifier();
        pre   = new Layer2PreCheck(scope, res);
        chain = new MockChainReadings();
        // the two-address binding: existence against L1, verdict against L2
        bond  = new CompletenessBond(IScopeRegistry(address(scope)), ILayer2PreCheck(address(pre)));
        PIN   = block.number; // pinned, already-mined (pre-outcome) block
        vm.deal(address(this), 100 ether);
    }

    receive() external payable {} // accept the slashed bounty as challenger

    // ───────────── proof helpers (mirror ContestFlow.t.sol / ChainNativeValueFidelity.t.sol) ────────
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
    function _delta(bytes32 xId, uint8 opt) internal pure returns (bytes memory) {
        return abi.encode(Vote({sourceId: xId, option: opt}));
    }

    // ──────────────────────── type-1 scope builder (mirrors ChainNativeValueFidelity) ───────────────
    /// Commit a robust 6-1 WIN chain-native scope. Under a 50% quorum on a 6-1 WIN base:
    ///   • an authentic absent X(WIN)  → stays WIN  → IMMATERIAL (authentic, guard 7 passes, no flip)
    ///   • an authentic absent X(LOSS) → 6-2/8 = 75% WIN still → MATERIAL needs the 3-3-1 base, see below
    /// To get a clean material/immaterial pair on the SAME committed scope (required for no-lockout),
    /// we use a 3-3-1 UNCERTAIN base where:
    ///   • authentic X(LOSS) → 3-3-2/8 → WIN/DRAW still tie at top → NO_QUORUM → IMMATERIAL
    ///   • authentic X(WIN)  → 4-3-1/8 = 50% WIN sole top → flips NO_QUORUM→WIN → MATERIAL
    /// Both X readings are seeded authentic so guard 7 passes; materiality is the only variable.
    function _commitType1(string memory tag)
        internal
        returns (bytes32 scopeId, bytes32 scopeRoot, bytes memory a, bytes32[] memory ids)
    {
        string[7] memory names = [
            string.concat(tag, "-1"), string.concat(tag, "-2"), string.concat(tag, "-3"),
            string.concat(tag, "-4"), string.concat(tag, "-5"), string.concat(tag, "-6"),
            string.concat(tag, "-7")
        ];
        uint8[7] memory opts = [WIN, WIN, WIN, DRAW, DRAW, DRAW, LOSS]; // 3-3-1 → UNCERTAIN base

        Vote[] memory real = new Vote[](7);
        ids = new bytes32[](7);
        for (uint256 i = 0; i < 7; i++) {
            ids[i]  = _id(names[i]);
            real[i] = Vote({sourceId: ids[i], option: opts[i]});
        }
        ids = _sort(ids);
        for (uint256 i = 0; i < real.length; i++) chain.setValue(real[i].sourceId, PIN, real[i].option);

        scopeId   = _id(tag);
        scopeRoot = _bind(_root(ids), ids.length);
        pre.commitScope(scopeId, scopeRoot, abi.encode(uint256(7), uint256(5000)), clf);
        res.commitChainSource(scopeId, chain, PIN); // type-1 pre-outcome commit (no value root)
        a = abi.encode(real); // honest base = the actual chain readings
    }

    // ═══════════════════════════════════ A — TYPE-1 (real separation) ═══════════════════════════════

    // ───────────────────────────── TEST 1: wiring ─────────────────────────────────────
    /// postBond existence is checked against the REAL L1 registry.
    function test_integration_postBond_realScopeRegistry() public {
        (bytes32 scopeId, bytes32 scopeRoot,,) = _commitType1("int-wiring");
        bytes32 bondId = bond.postBond{value: 1 ether}(scopeId, scopeRoot, 1 days);
        (uint256 amount,,,, bool slashed,) = bond.survival(bondId);
        assertEq(amount, 1 ether, "live bond carries the staked bounty");
        assertFalse(slashed, "fresh bond is not slashed");
        vm.expectRevert(bytes("scope not committed"));
        bond.postBond{value: 1 ether}(_id("never-committed"), scopeRoot, 1 days);
    }

    // ───────────────────────────── TEST 2: material slash (type-1) ────────────────────
    /// A material omission slashes through all four guards INCLUDING guard 7 (authentic X value);
    /// bounty pays the challenger. X(WIN) on the 3-3-1 base → 4-3-1/8 = 50% WIN → flips → material.
    function test_integration_materialOmission_slashes_throughRealContest() public {
        (bytes32 scopeId, bytes32 scopeRoot, bytes memory a, bytes32[] memory ids) = _commitType1("int-material");
        bytes32 bondId = bond.postBond{value: 1 ether}(scopeId, scopeRoot, 1 days);

        bytes memory X = bytes("int-material-X"); bytes32 xId = keccak256(X);
        chain.setValue(xId, PIN, WIN);  // X's AUTHENTIC reading — guard 7 passes
        bytes memory proof = abi.encode(a, _delta(xId, WIN), abi.encode(_makeNI(ids, xId)));

        uint256 balBefore = address(this).balance;
        bond.challenge(bondId, X, proof);

        (uint256 amount,,, uint64 resolvedAt, bool slashed, bool challenged) = bond.survival(bondId);
        assertTrue(slashed,  "material omission must slash through real contest()");
        assertTrue(challenged, "challenged aliases slashed");
        assertGt(resolvedAt, 0, "slashed bond is resolved");
        assertEq(amount, 1 ether, "amount preserved as the historical bounty record");
        assertEq(address(this).balance, balBefore + 1 ether, "bounty pays the challenger");
    }

    // ───────────────────────────── TEST 3: immaterial stands (type-1) ─────────────────
    /// An authentic-but-immaterial omission passes guard 7 yet does NOT flip the verdict, so it does
    /// NOT slash — the bond stands (sufficiency, Guarantee 1). X(LOSS) → 3-3-2/8 → WIN/DRAW still tie at top → NO_QUORUM → not material.
    function test_integration_immaterialOmission_doesNotSlash_bondStands() public {
        (bytes32 scopeId, bytes32 scopeRoot, bytes memory a, bytes32[] memory ids) = _commitType1("int-immaterial");
        bytes32 bondId = bond.postBond{value: 1 ether}(scopeId, scopeRoot, 1 days);

        bytes memory X = bytes("int-immaterial-X"); bytes32 xId = keccak256(X);
        chain.setValue(xId, PIN, LOSS); // X's AUTHENTIC reading — guard 7 passes; 3-3-2 keeps the WIN/DRAW tie → NO_QUORUM → not material
        bytes memory proof = abi.encode(a, _delta(xId, LOSS), abi.encode(_makeNI(ids, xId)));

        bond.challenge(bondId, X, proof);

        (,,, uint64 resolvedAt, bool slashed,) = bond.survival(bondId);
        assertFalse(slashed,   "authentic-but-immaterial omission must not slash");
        assertEq(resolvedAt, 0, "bond stands - still live");
    }

    // ───────────────────────────── TEST 4: NO-LOCKOUT (type-1) ────────────────────────
    /// THE property, by real separation. A failed (non-separating) challenge does NOT lock the bond
    /// against a later genuine material slash — on the real contest(), guard 7 included. Step 1: an
    /// authentic immaterial X(LOSS) → separated=false → bond stands. Step 2: an authentic material
    /// X(WIN) on the SAME standing bond → separated=true → slash. Prior failure didn't pre-burn it.
    function test_integration_noLockout_failedThenMaterial_realContest() public {
        (bytes32 scopeId, bytes32 scopeRoot, bytes memory a, bytes32[] memory ids) = _commitType1("int-nolockout");
        bytes32 bondId = bond.postBond{value: 1 ether}(scopeId, scopeRoot, 1 days);

        // 1. authentic immaterial challenge — bond must stand
        bytes memory X1 = bytes("int-nolockout-X1"); bytes32 xId1 = keccak256(X1);
        chain.setValue(xId1, PIN, LOSS);
        bond.challenge(bondId, X1, abi.encode(a, _delta(xId1, LOSS), abi.encode(_makeNI(ids, xId1))));
        (,,, uint64 r1, bool s1,) = bond.survival(bondId);
        assertFalse(s1, "non-separating challenge must not slash");
        assertEq(r1, 0, "bond still live after a failed challenge");

        // 2. authentic material challenge on the SAME bond — must still slash (no lockout)
        bytes memory X2 = bytes("int-nolockout-X2"); bytes32 xId2 = keccak256(X2);
        chain.setValue(xId2, PIN, WIN);
        bond.challenge(bondId, X2, abi.encode(a, _delta(xId2, WIN), abi.encode(_makeNI(ids, xId2))));
        (,,, uint64 r2, bool s2,) = bond.survival(bondId);
        assertTrue(s2, "a prior failed challenge MUST NOT lock out a genuine material slash");
        assertGt(r2, 0, "bond resolved by the material challenge");
    }

    // ═══════════════════════════ B — TYPE-2 (clean, non-locking deferral) ════════════════════════════

    // ───────────────────────────── TEST 5: type-2 deferral does not lock ──────────────
    /// THE type-2 residual property. Under the guard-7 wire a type-2 (off-chain value) bond challenge
    /// reverts at guard 7 (value can't be recomputed on-chain → defer to the source-auth leg). This
    /// test pins that the revert is CLEAN: challenge() has no catch, so the whole tx reverts and NO
    /// bond state is written. The committer is not locked (bond live, not slashed) and the challenger
    /// strands nothing (their reverted tx mutated no state, kept their own funds). no-lockout holds for
    /// type-2 by safe deferral. The richer "park pending source-auth" behavior is a future leg (#8 defer).
    function test_integration_type2Challenge_defersCleanly_noLock() public {
        // Stand up a parallel TYPE-2 stack (ResolutionCommitment) sharing the same L1 + classifier.
        ResolutionCommitment res2 = new ResolutionCommitment();
        Layer2PreCheck       pre2 = new Layer2PreCheck(scope, res2);
        CompletenessBond     bond2 = new CompletenessBond(IScopeRegistry(address(scope)), ILayer2PreCheck(address(pre2)));

        // Commit a 2WIN-2LOSS type-2 scope (committed-root resolution, no chain source).
        string[4] memory names = ["t2-A", "t2-B", "t2-C", "t2-D"];
        uint8[4]  memory opts  = [WIN, WIN, LOSS, LOSS];
        Vote[] memory real = new Vote[](4);
        bytes32[] memory ids = new bytes32[](4);
        for (uint256 i = 0; i < 4; i++) { ids[i] = _id(names[i]); real[i] = Vote({sourceId: ids[i], option: opts[i]}); }
        ids = _sort(ids);
        bytes memory a = abi.encode(real);

        bytes32 scopeId   = _id("int-type2-defer");
        bytes32 scopeRoot = _bind(_root(ids), ids.length);
        pre2.commitScope(scopeId, scopeRoot, abi.encode(uint256(4), uint256(6000)), clf);
        pre2.commitResolution(scopeId, res2.computeResolutionRoot(real)); // type-2 committed root

        bytes32 bondId = bond2.postBond{value: 1 ether}(scopeId, scopeRoot, 1 days);

        // Snapshot pre-challenge bond state + challenger balance.
        (uint256 amt0,,, uint64 r0, bool sl0,) = bond2.survival(bondId);
        uint256 balBefore = address(this).balance;

        // A type-2 bond challenge: even a would-be-material X(LOSS) cannot separate in-contract —
        // guard 7 returns false for type-2 and reverts. Assert the revert is exactly the deferral.
        bytes memory X = bytes("t2-X-LOSS"); bytes32 xId = keccak256(X);
        bytes memory proof = abi.encode(a, _delta(xId, LOSS), abi.encode(_makeNI(ids, xId)));
        vm.expectRevert(bytes("guard 7: X value does not reproduce committed reading"));
        bond2.challenge(bondId, X, proof);

        // CLEAN deferral: no bond state mutated, committer not locked, challenger stranded nothing.
        (uint256 amt1,,, uint64 r1, bool sl1, bool ch1) = bond2.survival(bondId);
        assertEq(amt1, amt0,   "amount unchanged by a deferred challenge");
        assertEq(r1,  r0,      "bond not resolved by a deferred challenge - still live");
        assertEq(sl1, sl0,     "bond not slashed by a deferred challenge");
        assertFalse(ch1,       "deferred challenge does not mark challenged");
        assertEq(r1, 0,        "committer not locked - bond remains live for a future source-auth challenge");
        assertEq(address(this).balance, balBefore, "challenger strands nothing - reverted tx kept funds");
    }
}
