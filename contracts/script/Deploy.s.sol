// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {BIP340Verifier} from "../src/BIP340Verifier.sol";
import {RecoveryEscrow} from "../src/RecoveryEscrow.sol";

/// @notice Deploy the recovery-escrow stack: BIP340Verifier(issuer) → RecoveryEscrow(verifier).
/// @dev env:
///   PRIVATE_KEY   — deployer key (uint).
///   ISSUER_PUBKEY — x-only (32-byte) pubkey the verifier pins as the receipt issuer. Default policy:
///                   the recovery AGENT's signing key (same x-only key `buildCommitEvent`/AGENT_PUBKEY
///                   signs the kind-30078 commit with) — owner-binding rides on the on-chain delivery
///                   check + nullifier, which are key-independent. (Set to the invinoveritas issuer key
///                   instead if the proof is re-issued by the verifier — pending Fede's confirm.)
///
/// Run:
///   forge script script/Deploy.s.sol:Deploy --rpc-url $RPC_URL --broadcast
contract Deploy is Script {
    function run() external returns (BIP340Verifier verifier, RecoveryEscrow escrow) {
        bytes32 issuer = vm.envBytes32("ISSUER_PUBKEY");
        uint256 pk = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(pk);
        verifier = new BIP340Verifier(issuer);
        escrow = new RecoveryEscrow(verifier);
        vm.stopBroadcast();

        console2.log("BIP340Verifier deployed at:", address(verifier));
        console2.log("RecoveryEscrow deployed at:", address(escrow));
        console2.log("pinned issuer x-only pubkey:");
        console2.logBytes32(issuer);
    }
}
