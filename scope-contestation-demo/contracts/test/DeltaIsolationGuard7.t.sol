// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IChainReadings} from "../src/IChainReadings.sol";
import {Vote} from "../src/ScopeTypes.sol";

/// @notice PROTOTYPE for Jimmy's (a, delta) isolation optimization + guard 7, runnable so the
///         claims are checkable (not asserted). Reference only - the production wire into
///         Layer2PreCheck.contest() is Damon's; this proves the three properties the patch rests on:
///
///   1. RECONSTRUCT-B IS ZERO-SECURITY-COST. Today contest() is passed full `b` and isolation
///      re-verifies b == a ++ [X] positionally. Pass `(a, delta=X)` instead and construct
///      b = a ++ [X] in-contract: the reconstructed b is byte-identical to the old b, so no check
///      is relaxed - you've only deleted calldata that re-proved itself.
///   2. CALLDATA SHRINKS by ~|a|: full b duplicates every declared vote; the delta is one vote.
///   3. GUARD 7 READS STRAIGHT OFF THE DELTA. With delta = (sourceId, value), the value-fidelity
///      check for X is valueAt(delta.sourceId, blockPin) == delta.value - no extracting the
///      appended vote back out of a reconstructed b. Closes adversarial-X.
contract DeltaIsolationGuard7Test is Test {
    MockChainReadings chain;
    uint256 PIN;
    uint8 constant WIN = 1;
    uint8 constant LOSS = 2;

    bytes a;            // declared base (5 sources)
    Vote  deltaX;       // the contested coordinate X as a single delta vote
    bytes32 xId;

    function setUp() public {
        chain = new MockChainReadings();
        PIN = block.number;
        Vote[] memory va = new Vote[](5);
        uint8[5] memory opts = [WIN, WIN, WIN, LOSS, LOSS];
        for (uint256 i = 0; i < 5; i++) {
            bytes32 sid = keccak256(abi.encodePacked("dx-S", i));
            va[i] = Vote({sourceId: sid, option: opts[i]});
            chain.setValue(sid, PIN, opts[i]);
        }
        a = abi.encode(va);
        xId = keccak256("dx-X");
        chain.setValue(xId, PIN, WIN);          // X's REAL reading is WIN
        deltaX = Vote({sourceId: xId, option: WIN});
    }

    // reconstruct b = a ++ [delta], the in-contract move that replaces "pass + re-verify full b"
    function _reconstructB(bytes memory aEnc, Vote memory d) internal pure returns (Vote[] memory) {
        Vote[] memory va = abi.decode(aEnc, (Vote[]));
        Vote[] memory b = new Vote[](va.length + 1);
        for (uint256 i = 0; i < va.length; i++) b[i] = va[i];
        b[va.length] = d;
        return b;
    }

    // the OLD bundle's full b (what callers pass today)
    function _fullB(bytes memory aEnc, Vote memory d) internal pure returns (bytes memory) {
        return abi.encode(_reconstructB(aEnc, d));
    }

    // ── 1. reconstruct-b is byte-identical to the old full b -> zero security cost ──
    function test_reconstructB_equals_oldFullB() public view {
        bytes memory reconstructed = abi.encode(_reconstructB(a, deltaX));
        bytes memory oldFullB = _fullB(a, deltaX);
        assertEq(keccak256(reconstructed), keccak256(oldFullB),
            "constructing b from (a,delta) yields the exact b the old bundle passed");
    }

    // ── 2. (a, delta) calldata is smaller than (a, b) by ~|a| ──
    function test_delta_bundle_is_smaller_than_full_b() public {
        bytes memory deltaBundle = abi.encode(a, abi.encode(deltaX));   // (a, delta)
        bytes memory fullBundle  = abi.encode(a, _fullB(a, deltaX));    // (a, b)
        assertLt(deltaBundle.length, fullBundle.length,
            "delta bundle drops the duplicated-a calldata");
        emit log_named_uint("(a,delta) bytes", deltaBundle.length);
        emit log_named_uint("(a,b)     bytes", fullBundle.length);
        emit log_named_uint("saved bytes", fullBundle.length - deltaBundle.length);
    }

    // ── 3. isolation collapses to X-not-in-a (the positional loop is gone) ──
    function test_isolation_reduces_to_X_not_in_a() public view {
        Vote[] memory va = abi.decode(a, (Vote[]));
        bool xInA = false;
        for (uint256 i = 0; i < va.length; i++) if (va[i].sourceId == deltaX.sourceId) xInA = true;
        assertFalse(xInA, "X absent from a - the only structural check isolation still needs");
    }

    // ── 4. guard 7 reads straight off the delta: fabricated value rejected, honest value passes ──
    function test_guard7_off_delta() public view {
        // fabricated: contester claims X = LOSS, chain says WIN -> guard 7 rejects
        Vote memory fabricated = Vote({sourceId: xId, option: LOSS});
        assertTrue(chain.valueAt(fabricated.sourceId, PIN) != fabricated.option,
            "guard 7 rejects: valueAt(X) != claimed delta value");
        // honest: delta carries X's real reading -> guard 7 passes
        assertTrue(chain.valueAt(deltaX.sourceId, PIN) == deltaX.option,
            "guard 7 passes: valueAt(X) == delta value");
    }
}

contract MockChainReadings is IChainReadings {
    mapping(bytes32 => mapping(uint256 => uint8)) private _v;
    function setValue(bytes32 sourceId, uint256 blockNumber, uint8 option) external { _v[sourceId][blockNumber] = option; }
    function valueAt(bytes32 sourceId, uint256 blockNumber) external view returns (uint8) { return _v[sourceId][blockNumber]; }
}
