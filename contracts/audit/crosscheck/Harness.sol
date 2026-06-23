// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;
import {BIP340} from "../../src/BIP340.sol";

/// Test-only wrapper: exposes the `internal` library function externally with the exact call
/// shape used by test/BIP340.t.sol::_verify. The library code inlines into this harness, so the
/// bytecode executed here is identical to what the forge suite exercises.
contract Harness {
    function verify(bytes32 px, bytes32 rx, bytes32 s, bytes32 m) external view returns (bool) {
        return BIP340.verify(px, rx, s, m);
    }
    function N() external pure returns (uint256) { return BIP340.N; }
}
