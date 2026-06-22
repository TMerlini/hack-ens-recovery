// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {RecoveryEscrow} from "../src/RecoveryEscrow.sol";
import {IReceiptVerifier} from "../src/IReceiptVerifier.sol";

/// Mock verifier: receiptProof = abi.encode(bool valid, bytes32 artifactHash).
/// Mirrors the seam without committing to BIP-340 / attestor / optimistic (the open call).
contract MockVerifier is IReceiptVerifier {
    function verify(bytes32 expectArtifactHash, bytes calldata receiptProof)
        external
        pure
        returns (bool valid, bool artifactHashMatches)
    {
        (bool v, bytes32 artifactHash) = abi.decode(receiptProof, (bool, bytes32));
        return (v, artifactHash == expectArtifactHash);
    }
}

/// Minimal ERC-721 with a settable owner — stands in for the ENS BaseRegistrar.
contract MockERC721 {
    mapping(uint256 => address) public owners;

    function setOwner(uint256 tokenId, address owner) external {
        owners[tokenId] = owner;
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return owners[tokenId];
    }
}

contract RecoveryEscrowTest is Test {
    RecoveryEscrow escrow;
    MockVerifier verifier;
    MockERC721 asset;

    address requester = makeAddr("requester");
    address agent = makeAddr("agent");
    address owner = makeAddr("outputAddress"); // owner-specified destination
    address attacker = makeAddr("attacker");

    bytes32 constant H = keccak256("expect_artifact_hash"); // opaque commitment stand-in
    uint256 constant TOKEN_ID = 42;
    uint256 constant FEE = 1 ether;
    uint64 expiry;

    function setUp() public {
        verifier = new MockVerifier();
        escrow = new RecoveryEscrow(verifier);
        asset = new MockERC721();
        expiry = uint64(block.timestamp + 7 days);
        vm.deal(requester, 10 ether);
    }

    function _open() internal {
        vm.prank(requester);
        escrow.openJob{value: FEE}(H, owner, address(asset), TOKEN_ID, agent, expiry);
    }

    function _proof(bool valid, bytes32 artifactHash) internal pure returns (bytes memory) {
        return abi.encode(valid, artifactHash);
    }

    function test_openJob_storesAndEscrows() public {
        _open();
        assertEq(address(escrow).balance, FEE);
        RecoveryEscrow.Job memory j = escrow.getJob(H);
        assertEq(j.requester, requester);
        assertEq(j.outputAddress, owner);
        assertEq(uint8(j.status), uint8(RecoveryEscrow.Status.Open));
    }

    function test_openJob_duplicateReverts() public {
        _open();
        vm.prank(requester);
        vm.expectRevert(RecoveryEscrow.AlreadyExists.selector);
        escrow.openJob{value: FEE}(H, owner, address(asset), TOKEN_ID, agent, expiry);
    }

    function test_release_happyPath() public {
        _open();
        asset.setOwner(TOKEN_ID, owner); // delivered to output_address
        uint256 before = agent.balance;
        // permissionless caller (attacker can trigger — contract enforces)
        vm.prank(attacker);
        escrow.release(H, _proof(true, H));
        assertEq(agent.balance, before + FEE);
        assertTrue(escrow.spent(H)); // nullified
        assertEq(uint8(escrow.getJob(H).status), uint8(RecoveryEscrow.Status.Released));
    }

    function test_release_revertsWhenNotValid() public {
        _open();
        asset.setOwner(TOKEN_ID, owner);
        vm.expectRevert(RecoveryEscrow.ReceiptNotValid.selector);
        escrow.release(H, _proof(false, H));
    }

    function test_release_revertsOnArtifactMismatch() public {
        _open();
        asset.setOwner(TOKEN_ID, owner);
        vm.expectRevert(RecoveryEscrow.ArtifactMismatch.selector);
        escrow.release(H, _proof(true, keccak256("some_other_job")));
    }

    /// The headline invariant: valid==true is NEVER enough without on-chain delivery.
    function test_release_neverOnValidAlone() public {
        _open();
        // valid + artifact match, but asset NOT delivered to output_address
        asset.setOwner(TOKEN_ID, attacker);
        vm.expectRevert(RecoveryEscrow.NotDelivered.selector);
        escrow.release(H, _proof(true, H));
    }

    function test_release_replayBlockedByNullifier() public {
        _open();
        asset.setOwner(TOKEN_ID, owner);
        escrow.release(H, _proof(true, H));
        // same receipt, same hash — job is Released now
        vm.expectRevert(RecoveryEscrow.NotOpen.selector);
        escrow.release(H, _proof(true, H));
        // and the hash can never be re-opened
        vm.prank(requester);
        vm.expectRevert(RecoveryEscrow.AlreadySpent.selector);
        escrow.openJob{value: FEE}(H, owner, address(asset), TOKEN_ID, agent, expiry);
    }

    function test_refund_afterExpiry() public {
        _open();
        vm.warp(expiry + 1);
        uint256 before = requester.balance;
        vm.prank(requester);
        escrow.refund(H);
        assertEq(requester.balance, before + FEE);
        assertEq(uint8(escrow.getJob(H).status), uint8(RecoveryEscrow.Status.Refunded));
    }

    function test_refund_beforeExpiryReverts() public {
        _open();
        vm.prank(requester);
        vm.expectRevert(RecoveryEscrow.NotExpired.selector);
        escrow.refund(H);
    }

    function test_refund_onlyRequester() public {
        _open();
        vm.warp(expiry + 1);
        vm.prank(attacker);
        vm.expectRevert(RecoveryEscrow.OnlyRequester.selector);
        escrow.refund(H);
    }
}
