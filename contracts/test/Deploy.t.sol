// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {BIP340Verifier} from "../src/BIP340Verifier.sol";
import {RecoveryEscrow} from "../src/RecoveryEscrow.sol";

contract DeployTest is Test {
    function test_deployWiresEscrowToVerifier() public {
        vm.setEnv("PRIVATE_KEY", vm.toString(uint256(0xA11CE)));
        vm.setEnv("ISSUER_PUBKEY", vm.toString(bytes32(uint256(0x1234))));

        Deploy d = new Deploy();
        (BIP340Verifier verifier, RecoveryEscrow escrow) = d.run();

        assertEq(address(escrow.verifier()), address(verifier), "escrow must point at the deployed verifier");
        assertEq(verifier.issuerPubkeyX(), bytes32(uint256(0x1234)), "verifier must pin the configured issuer");
    }
}
