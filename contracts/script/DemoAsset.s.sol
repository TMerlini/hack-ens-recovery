// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

// DEMO ONLY — a minimal settable-owner ERC-721 to exercise the escrow's on-chain delivery check on a
// testnet (stands in for the ENS BaseRegistrar). Not part of the production contract set.
import {Script, console2} from "forge-std/Script.sol";

contract DemoERC721 {
    mapping(uint256 => address) public owners;
    function mint(uint256 tokenId, address to) external { owners[tokenId] = to; }
    function ownerOf(uint256 tokenId) external view returns (address) { return owners[tokenId]; }
}

contract DemoAsset is Script {
    function run() external returns (address asset) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        uint256 tokenId = vm.envUint("DEMO_TOKEN_ID");
        address to = vm.envAddress("DEMO_OUTPUT");
        vm.startBroadcast(pk);
        DemoERC721 nft = new DemoERC721();
        nft.mint(tokenId, to);
        vm.stopBroadcast();
        asset = address(nft);
        console2.log("DemoERC721:", asset);
        console2.log("minted tokenId to:", to);
    }
}
