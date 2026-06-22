// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {BIP340Verifier} from "../src/BIP340Verifier.sol";

// Integration tests for the IReceiptVerifier impl A. The vector is a REAL signed kind-30078
// invinoveritas commit event, with receiptProof packed by the SDK's packReceiptProof() — so this
// proves on-chain verify() agrees with off-chain verifyFullFlow() on byte-identical input.
contract BIP340VerifierTest is Test {
    BIP340Verifier verifier;

    bytes32 constant ISSUER = 0xfa4324e30973b321e454d7a1f7feaf6d83f20706bc26925e0f5406fa4465caaa;
    bytes32 constant ARTIFACT = 0x567f91ee12bdcb1ae6bdf4ac43acde99826637716117a45ba74b2f9c199896d9;

    // abi.encode(px, rx, s, preimage) for the signed recovery_receipt (job-7).
    bytes constant PROOF =
        hex"fa4324e30973b321e454d7a1f7feaf6d83f20706bc26925e0f5406fa4465caaa7dda769207a336ca96345aad24ef27c02bcc0f90360c13a2e2044317447155bbc3657df3a7798f9898b44613d1e35e1bf40576ce5b81bc6d5373e668f13fcc2d0000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000011c5b302c2266613433323465333039373362333231653435346437613166376665616636643833663230373036626332363932356530663534303666613434363563616161222c313738323135303030302c33303037382c5b5d2c227b5c22736368656d615c223a5c226f6e636861696e2d61692e636f6d6d69742e76305c222c5c2261727469666163745f686173685c223a5c22353637663931656531326264636231616536626466346163343361636465393938323636333737313631313761343562613734623266396331393938393664395c222c5c22636f6d6d69747465645f61745c223a313738323135303030302c5c226a7564676d656e745f747970655c223a5c227265636f766572795f726563656970745c227d225d00000000";

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
