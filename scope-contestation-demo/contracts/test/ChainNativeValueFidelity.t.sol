// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ScopeContestation} from "../src/ScopeContestation.sol";
import {MajorityClassifier} from "../src/MajorityClassifier.sol";
import {Layer2PreCheck} from "../src/Layer2PreCheck.sol";
import {ChainNativeResolution} from "../src/ChainNativeResolution.sol";
import {IChainReadings} from "../src/IChainReadings.sol";
import {Vote, NIProof} from "../src/ScopeTypes.sol";

/// A historical-addressable on-chain readings source (test double). A production reader is a
/// round/block-keyed oracle; here values are stored per (sourceId, block) so valueAt() is deterministic.
contract MockChainReadings is IChainReadings {
    mapping(bytes32 => mapping(uint256 => uint8)) private _v;

    function setValue(bytes32 sourceId, uint256 blockNumber, uint8 option) external {
        _v[sourceId][blockNumber] = option;
    }

    function valueAt(bytes32 sourceId, uint256 blockNumber) external view returns (uint8) {
        return _v[sourceId][blockNumber];
    }
}

/// @notice Type-1 (chain-native) value-fidelity, end-to-end through the SAME Layer2PreCheck.contest()
///         pipeline as Damon's type-2 tests — only the IResolutionCommitment impl is swapped for
///         {ChainNativeResolution}. Proves the type-1 recompute leg drops into the unchanged interface
///         and gate order: verifyAbsence → verifyScopeComplete → verifyValueFidelity → isolation → classify.
contract ChainNativeValueFidelityTest is Test {
    ScopeContestation    scope;
    MajorityClassifier   clf;
    ChainNativeResolution res;
    Layer2PreCheck       pre;
    MockChainReadings    chain;
    uint256              PIN;

    uint8 constant WIN  = 1;
    uint8 constant LOSS = 2;
    uint8 constant DRAW = 3;

    function setUp() public {
        scope = new ScopeContestation();
        clf   = new MajorityClassifier();
        res   = new ChainNativeResolution();
        pre   = new Layer2PreCheck(scope, res);
        chain = new MockChainReadings();
        PIN   = block.number; // pinned, already-mined (pre-outcome) block
    }

    // Commit the real readings onto the chain source at the pinned block.
    function _seedChain(Vote[] memory real) internal {
        for (uint256 i = 0; i < real.length; i++) {
            chain.setValue(real[i].sourceId, PIN, real[i].option);
        }
    }

    // ── THE KEY TEST: adversarial-a with chain-native readings is rejected by guard 3 ──
    // Real on-chain resolution is a robust 6-1 WIN. A contester fabricates a coordinate-complete `a`
    // (boundary-split 3-3-1) that passes verifyAbsence + verifyScopeComplete, but verifyValueFidelity
    // RECOMPUTES the values from chain and they don't match → revert. Same outcome as the type-2 leg,
    // reached by recompute-from-public instead of a committed root.
    function test_type1_valueFidelity_adversarialA_reverts() public {
        string[7] memory names = ["t1-S1", "t1-S2", "t1-S3", "t1-S4", "t1-S5", "t1-S6", "t1-S7"];
        uint8[7]  memory opts  = [WIN, WIN, WIN, WIN, WIN, WIN, DRAW];

        Vote[] memory real = new Vote[](7);
        bytes32[] memory ids = new bytes32[](7);
        for (uint256 i = 0; i < 7; i++) {
            ids[i]  = _id(names[i]);
            real[i] = Vote({sourceId: ids[i], option: opts[i]});
        }
        ids = _sort(ids);
        _seedChain(real);

        bytes32 scopeId   = _id("t1-market-vf");
        bytes32 scopeRoot = _bind(_root(ids), ids.length);
        bytes memory params = abi.encode(uint256(7), uint256(5000));
        pre.commitScope(scopeId, scopeRoot, params, clf);
        res.commitChainSource(scopeId, chain, PIN); // type-1 pre-outcome commit (no value root)

        // Fabricated boundary-split: same declared sourceIds, adversarial values.
        Vote[] memory fake = new Vote[](7);
        fake[0] = Vote({sourceId: ids[0], option: WIN});
        fake[1] = Vote({sourceId: ids[1], option: WIN});
        fake[2] = Vote({sourceId: ids[2], option: WIN});
        fake[3] = Vote({sourceId: ids[3], option: DRAW});
        fake[4] = Vote({sourceId: ids[4], option: DRAW});
        fake[5] = Vote({sourceId: ids[5], option: DRAW});
        fake[6] = Vote({sourceId: ids[6], option: LOSS});
        bytes memory aFake = abi.encode(fake);

        bytes memory X = bytes("t1-X-extra");
        bytes32 xId    = keccak256(X);
        bytes memory b = _append(aFake, xId, WIN);
        bytes memory proof = abi.encode(aFake, b, abi.encode(_makeNI(ids, xId)));

        vm.expectRevert(bytes("value fidelity: a does not reproduce the committed resolution"));
        pre.contest(scopeId, X, proof);
    }

    // ── Happy path: honest `a` reproduces the chain readings; a genuine absent X is material ──
    function test_type1_valueFidelity_fullHappyPath_separates() public {
        string[7] memory names = ["t1-hp-1", "t1-hp-2", "t1-hp-3", "t1-hp-4", "t1-hp-5", "t1-hp-6", "t1-hp-7"];
        uint8[7]  memory opts  = [WIN, WIN, WIN, DRAW, DRAW, DRAW, LOSS]; // 3-3-1 → UNCERTAIN

        Vote[] memory real = new Vote[](7);
        bytes32[] memory ids = new bytes32[](7);
        for (uint256 i = 0; i < 7; i++) {
            ids[i]  = _id(names[i]);
            real[i] = Vote({sourceId: ids[i], option: opts[i]});
        }
        ids = _sort(ids);
        _seedChain(real);

        bytes32 scopeId   = _id("t1-market-hp");
        bytes32 scopeRoot = _bind(_root(ids), ids.length);
        bytes memory params = abi.encode(uint256(7), uint256(5000));
        pre.commitScope(scopeId, scopeRoot, params, clf);
        res.commitChainSource(scopeId, chain, PIN);

        bytes memory a = abi.encode(real); // honest base = the actual chain readings
        bytes memory X = bytes("t1-hp-X");
        bytes32 xId    = keccak256(X);
        bytes memory b = _append(a, xId, WIN); // X(WIN) tips 4/8=50%≥50% → WIN
        bytes memory proof = abi.encode(a, b, abi.encode(_makeNI(ids, xId)));

        bool separated = pre.contest(scopeId, X, proof);
        assertTrue(separated, "X material to THE chain-native resolution must separate");
    }

    function test_type1_commitResolution_reverts_useChainSource() public {
        vm.expectRevert(bytes("ChainNativeResolution: use commitChainSource(scopeId, reader, blockPin)"));
        res.commitResolution(_id("x"), keccak256("y"));
    }

    // ───────────────────────── harness helpers (mirror ContestFlow.t.sol) ─────────────────────────
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
            bytes32[] memory nxt = new bytes32[]((m + 1) / 2); uint256 j = 0;
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
        for (uint256 i = 1; i < a.length; i++) {
            bytes32 k = a[i]; uint256 j = i;
            while (j > 0 && uint256(a[j - 1]) > uint256(k)) { a[j] = a[j - 1]; j--; }
            a[j] = k;
        }
        return a;
    }
    function _makeNI(bytes32[] memory ids, bytes32 cc) internal pure returns (NIProof memory p) {
        uint256 n = ids.length; p.count = n;
        if (uint256(cc) < uint256(ids[0])) { p.caseId = 1; p.loCoord = ids[0]; p.sibsLo = _siblings(ids, 0); return p; }
        if (uint256(cc) > uint256(ids[n - 1])) { p.caseId = 2; p.hiCoord = ids[n - 1]; p.sibsHi = _siblings(ids, n - 1); return p; }
        for (uint256 i = 0; i + 1 < n; i++) {
            if (uint256(ids[i]) < uint256(cc) && uint256(cc) < uint256(ids[i + 1])) {
                p.caseId = 0; p.loCoord = ids[i]; p.hiCoord = ids[i + 1];
                p.idxLo = i; p.sibsLo = _siblings(ids, i); p.sibsHi = _siblings(ids, i + 1); return p;
            }
        }
        revert("present");
    }
    function _append(bytes memory a, bytes32 xId, uint8 opt) internal pure returns (bytes memory) {
        Vote[] memory va = abi.decode(a, (Vote[]));
        Vote[] memory vb = new Vote[](va.length + 1);
        for (uint256 i = 0; i < va.length; i++) vb[i] = va[i];
        vb[va.length] = Vote({sourceId: xId, option: opt});
        return abi.encode(vb);
    }
}
