// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BIP340Verifier} from "../src/BIP340Verifier.sol";

// Integration tests for the IReceiptVerifier impl A. The vector is a REAL signed kind-30078
// invinoveritas commit event, with receiptProof packed by the SDK's packReceiptProof() — so this
// proves on-chain verify() agrees with off-chain verifyFullFlow() on byte-identical input.
contract BIP340VerifierTest is Test {
    BIP340Verifier verifier;

    bytes32 constant ISSUER = 0x9f440a7baf7a4975f1fc345931cd24ce280a3f1b19f141b35b4661ac1f616216;
    bytes32 constant ARTIFACT = 0xd29f9c0a259e0a7f90f929a748ae30363a3f3e93358df4af05e6453ba7032765;

    // abi.encode(px, rx, s, preimage) for the signed recovery_receipt (job-7), schema trustless-ai.commit.v0.
    bytes constant PROOF =
        hex"9f440a7baf7a4975f1fc345931cd24ce280a3f1b19f141b35b4661ac1f616216a9a440e11010700a8ea1ed0b24a1bec6f9f3913d4af20175cefcb781395059fbd939f8829235535661f0081200a56fc458615d8f8b2119221b676914173d2bbc0000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000011e5b302c2239663434306137626166376134393735663166633334353933316364323463653238306133663162313966313431623335623436363161633166363136323136222c313738323234373433322c33303037382c5b5d2c227b5c22736368656d615c223a5c2274727573746c6573732d61692e636f6d6d69742e76305c222c5c2261727469666163745f686173685c223a5c22643239663963306132353965306137663930663932396137343861653330333633613366336539333335386466346166303565363435336261373033323736355c222c5c22636f6d6d69747465645f61745c223a313738323234373433322c5c226a7564676d656e745f747970655c223a5c227265636f766572795f726563656970745c227d225d0000";

    function setUp() public {
        verifier = new BIP340Verifier(ISSUER);
    }

    function test_validReceipt_matchingHash() public view {
        (bool valid, bool matches) = verifier.verify(ARTIFACT, PROOF);
        assertTrue(valid, "genuine signed receipt from pinned issuer must be valid");
        assertTrue(matches, "committed artifact_hash must match expect");
    }

    function test_validReceipt_wrongExpectHash() public view {
        (bool valid, bool matches) = verifier.verify(bytes32(uint256(ARTIFACT) ^ 1), PROOF);
        assertTrue(valid, "signature is still genuine");
        assertFalse(matches, "wrong expect hash must NOT match (replay/wrong-job blocked)");
    }

    function test_wrongIssuerPin_invalid() public {
        BIP340Verifier other = new BIP340Verifier(bytes32(uint256(ISSUER) ^ 1));
        (bool valid, bool matches) = other.verify(ARTIFACT, PROOF);
        assertFalse(valid, "receipt not issued by the pinned key must be invalid");
        // hash still parses out of the (genuine) content regardless of issuer pin
        assertTrue(matches, "artifact_hash extraction is independent of the issuer pin");
    }

    function test_tamperedProof_invalid() public view {
        // flip one byte inside the signed content → sha256(preimage) changes → signature fails
        bytes memory bad = PROOF;
        bad[bad.length - 8] = bytes1(uint8(bad[bad.length - 8]) ^ 0x01);
        (bool valid,) = verifier.verify(ARTIFACT, bad);
        assertFalse(valid, "tampered preimage must fail the signature check");
    }

    function test_malformedProof_noRevert() public view {
        (bool valid, bool matches) = verifier.verify(ARTIFACT, hex"deadbeef");
        assertFalse(valid);
        assertFalse(matches);
    }

    function test_constructorRejectsZeroIssuer() public {
        vm.expectRevert(bytes("issuer pubkey required"));
        new BIP340Verifier(bytes32(0));
    }
}
