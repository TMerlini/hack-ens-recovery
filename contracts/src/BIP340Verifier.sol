// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IReceiptVerifier} from "./IReceiptVerifier.sol";
import {BIP340} from "./BIP340.sol";

/// @title BIP340Verifier — IReceiptVerifier impl A ("verify trusting no one").
/// @notice Confirms a kind-30078 invinoveritas receipt is a genuine BIP-340-signed proof and extracts
///         its committed `artifact_hash` — entirely on-chain, no trusted oracle, no verifier key as
///         release authority. The signature leg uses {BIP340} (ecrecover trick); the `artifact_hash`
///         bind is read out of the SAME signed preimage, so a valid signature is over the exact bytes
///         we parse. Pairs with the SDK's `packReceiptProof(event)` (byte-identical input both sides).
///
/// `receiptProof` = `abi.encode(bytes32 px, bytes32 rx, bytes32 s, bytes preimage)` where
/// `preimage` is the NIP-01 serialization `[0,"<pubkey>",<created_at>,<kind>,<tags>,"<content>"]`.
/// The message the signature commits to is `id = sha256(preimage)`.
///
/// `valid` = signature_valid ∧ issued_by_pinned_key ∧ is_proof_event(schema). The escrow ANDs this with
/// `artifactHashMatches` + an on-chain delivery check + a nullifier — never `valid` alone.
contract BIP340Verifier is IReceiptVerifier {
    /// @notice The pinned invinoveritas x-only pubkey. `valid` requires the receipt be issued by it.
    bytes32 public immutable issuerPubkeyX;

    // is_proof_event signal: the commit schema family, present in the (escaped) content.
    bytes private constant SCHEMA_MARKER = "trustless-ai.commit";
    // artifact_hash marker as it appears in the serialized (escaped) content: \"artifact_hash\":\"
    bytes private constant ARTIFACT_MARKER = "\\\"artifact_hash\\\":\\\"";

    constructor(bytes32 issuerPubkeyX_) {
        require(issuerPubkeyX_ != bytes32(0), "issuer pubkey required");
        issuerPubkeyX = issuerPubkeyX_;
    }

    /// @inheritdoc IReceiptVerifier
    function verify(bytes32 expectArtifactHash, bytes calldata receiptProof)
        external
        view
        returns (bool valid, bool artifactHashMatches)
    {
        // Tolerate malformed proofs — return (false,false), never revert (matches the off-chain verifier).
        if (receiptProof.length < 0x80) return (false, false);
        (bytes32 px, bytes32 rx, bytes32 s, bytes memory preimage) =
            abi.decode(receiptProof, (bytes32, bytes32, bytes32, bytes));

        bytes32 id = sha256(preimage); // the message the signature commits to (NIP-01 event id)

        bool sigOk = BIP340.verify(px, rx, s, id);
        bool issuerOk = (px == issuerPubkeyX);
        bool isProof = _contains(preimage, SCHEMA_MARKER);
        valid = sigOk && issuerOk && isProof;

        (bool found, bytes32 ah) = _extractArtifactHash(preimage);
        artifactHashMatches = found && (ah == expectArtifactHash);
    }

    // --- byte-scan helpers (over the SIGNED preimage) ----------------------------------------------

    /// @dev find `ARTIFACT_MARKER` then parse the following 64 hex chars into a bytes32.
    function _extractArtifactHash(bytes memory hay) private pure returns (bool, bytes32) {
        int256 at = _indexOf(hay, ARTIFACT_MARKER);
        if (at < 0) return (false, bytes32(0));
        uint256 start = uint256(at) + ARTIFACT_MARKER.length;
        if (start + 64 > hay.length) return (false, bytes32(0));
        uint256 acc;
        for (uint256 i = 0; i < 64; i++) {
            int256 nib = _hexNibble(hay[start + i]);
            if (nib < 0) return (false, bytes32(0));
            acc = (acc << 4) | uint256(nib);
        }
        return (true, bytes32(acc));
    }

    function _contains(bytes memory hay, bytes memory needle) private pure returns (bool) {
        return _indexOf(hay, needle) >= 0;
    }

    /// @dev naive substring search; bounded by preimage length (kilobytes), fine for a view call.
    function _indexOf(bytes memory hay, bytes memory needle) private pure returns (int256) {
        uint256 n = needle.length;
        if (n == 0 || hay.length < n) return -1;
        uint256 last = hay.length - n;
        for (uint256 i = 0; i <= last; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n; j++) {
                if (hay[i + j] != needle[j]) { ok = false; break; }
            }
            if (ok) return int256(i);
        }
        return -1;
    }

    function _hexNibble(bytes1 c) private pure returns (int256) {
        uint8 b = uint8(c);
        if (b >= 0x30 && b <= 0x39) return int256(uint256(b - 0x30));        // 0-9
        if (b >= 0x61 && b <= 0x66) return int256(uint256(b - 0x61 + 10));   // a-f
        if (b >= 0x41 && b <= 0x46) return int256(uint256(b - 0x41 + 10));   // A-F
        return -1;
    }
}
