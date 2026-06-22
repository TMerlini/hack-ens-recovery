// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BIP340} from "../src/BIP340.sol";

// Crypto-core tests for the BIP-340 ecrecover-trick verifier.
// Vectors are REAL BIP-340 signatures produced off-chain by noble-curves (the same library the
// invinoveritas SDK signs with). A green test_validSignature proves the on-chain verifier agrees
// with the canonical signer.
contract BIP340Test is Test {
    // Vector 1 — sk = sha256("bip340-verifier-test-key-1"); m = sha256("the message being signed ...")
    bytes32 constant PX = 0xc2dfd401c46c8d273b9b8deccf29eb8a56593f25421b91649904d56d28a784ad;
    bytes32 constant RX = 0xb2d7c6d2d094fd749657dabfefed129c764a9b495b620f50438231ba9be904a6;
    bytes32 constant S  = 0x7b3d8e2f90b1ba58ff7066d5f43346bb9cb0a09a27e10ad466fce1ad9469223b;
    bytes32 constant M  = 0xb6d2d081d098f3026715b07380b1571acda72d8c7fe18c002f1a447a1d88d307;

    function _verify(bytes32 px, bytes32 rx, bytes32 s, bytes32 m) internal view returns (bool) {
        return BIP340.verify(px, rx, s, m);
    }

    function test_validSignature() public view {
        assertTrue(_verify(PX, RX, S, M), "valid BIP-340 sig must verify");
    }

    function test_wrongMessage() public view {
        assertFalse(_verify(PX, RX, S, bytes32(uint256(M) ^ 1)), "flipped message must fail");
    }

    function test_wrongPubkey() public view {
        assertFalse(_verify(bytes32(uint256(PX) ^ 1), RX, S, M), "wrong pubkey must fail");
    }

    function test_tamperedS() public view {
        assertFalse(_verify(PX, RX, bytes32(uint256(S) ^ 1), M), "tampered s must fail");
    }

    function test_tamperedR() public view {
        assertFalse(_verify(PX, bytes32(uint256(RX) ^ 1), S, M), "tampered rx must fail");
    }

    function test_zeroInputsRejected() public view {
        assertFalse(_verify(bytes32(0), RX, S, M), "px=0 rejected");
        assertFalse(_verify(PX, RX, bytes32(0), M), "s=0 rejected");
        assertFalse(_verify(PX, bytes32(0), S, M), "rx=0 rejected");
    }

    function test_sAboveOrderRejected() public view {
        // s = N must be rejected (not in (0,N))
        assertFalse(_verify(PX, RX, bytes32(BIP340.N), M), "s>=N rejected");
    }
}
