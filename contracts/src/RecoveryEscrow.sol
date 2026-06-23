// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IReceiptVerifier} from "./IReceiptVerifier.sol";

interface IERC721 {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title RecoveryEscrow — owner-bound, independently-verifiable escrow for the recovery-agent flow.
/// @author TMerlini, babyblueviper1 (verify+ledger). Agent-type/ZKML framing: Jimmy Shi.
/// @notice Holds the fee for an asset-recovery job and releases it ONLY when all three locked
///         conditions hold (never on `valid` alone — that's the footgun the spec calls out):
///           1. valid               — receipt is a genuine signed invinoveritas proof  (via verifier)
///           2. artifactHashMatches — receipt.artifact_hash == this job's expectArtifactHash (via verifier)
///           3. on-chain delivery   — the asset's ownerOf(tokenId) == output_address   (checked HERE)
///         On release it nullifies expectArtifactHash (mark-spent) so a replayed receipt can't be
///         claimed twice. Owner-binding is structural: output_address lives inside expectArtifactHash
///         (computed off-chain via recompute.ts / the SDK) AND is re-checked on-chain at delivery.
///
///         Spec (LOCKED w/ Fede 2026-06-22):
///         https://gist.github.com/TMerlini/98b7dbeb221024b617b36c7e3b79e695
///
/// @dev expectArtifactHash is treated as an OPAQUE bytes32 commitment. It is a SHA-256 over canonical
///      JSON produced off-chain by the trustless-ai agent-sdk (artifactHash(normalizeSpec(spec))), NOT a
///      keccak/abi.encode value — so the contract does not (and cannot cheaply) recompute it. Its teeth
///      come from (a) the verifier confirming the signed receipt carries this exact hash, and (b) the
///      independent on-chain ownerOf delivery check. Confirmed w/ Fede (2026-06-22): keep a SINGLE
///      canonical sha256 hash end-to-end — deliberately NO parallel keccak/abi id (a second
///      canonicalization would re-create the cross-language drift we just removed).
contract RecoveryEscrow {
    enum Status {
        None,
        Open,
        Released,
        Refunded
    }

    struct Job {
        address requester; // opened + funded the job (refund destination)
        address agent; // paid on successful release
        address outputAddress; // the ONLY destination assets may go (owner-specified)
        address asset; // ERC-721 the rescued token lives in (e.g. ENS BaseRegistrar)
        uint256 tokenId; // the rescued token id
        uint256 fee; // escrowed amount (wei)
        uint64 expiry; // after this, requester may refund if still Open
        Status status;
    }

    /// @notice The receipt-validity leg (schnorr/`valid` + artifact match). Immutable: no admin can
    ///         swap the trust assumptions of a live escrow.
    IReceiptVerifier public immutable verifier;

    /// @notice job records keyed by expectArtifactHash (unique per job via the job_id salt).
    mapping(bytes32 => Job) public jobs;

    /// @notice nullifier — artifact hashes already settled (cannot be released again, ever).
    mapping(bytes32 => bool) public spent;

    /// @dev minimal reentrancy guard (CEI is already followed; this is defense-in-depth).
    uint256 private _lock = 1;

    event JobOpened(
        bytes32 indexed expectArtifactHash,
        address indexed requester,
        address indexed agent,
        address outputAddress,
        address asset,
        uint256 tokenId,
        uint256 fee,
        uint64 expiry
    );
    event Released(bytes32 indexed expectArtifactHash, address indexed agent, uint256 fee, address caller);
    event Refunded(bytes32 indexed expectArtifactHash, address indexed requester, uint256 fee);

    error AlreadyExists();
    error AlreadySpent();
    error NotOpen();
    error ZeroArg();
    error NoFee();
    error BadExpiry();
    error ReceiptNotValid();
    error ArtifactMismatch();
    error NotDelivered();
    error NotExpired();
    error OnlyRequester();
    error TransferFailed();
    error Reentrancy();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(IReceiptVerifier verifier_) {
        if (address(verifier_) == address(0)) revert ZeroArg();
        verifier = verifier_;
    }

    /// @notice Open + fund a recovery job. msg.value is the escrowed fee.
    /// @param expectArtifactHash H(job_id, target_wallet, output_address, asset_set) from the SDK (off-chain).
    /// @param outputAddress      owner-specified destination (must match what's baked into the hash).
    /// @param asset              ERC-721 contract holding the token to be rescued (e.g. ENS BaseRegistrar).
    /// @param tokenId            token id of the asset to be rescued.
    /// @param agent              recovery agent paid on successful release.
    /// @param expiry             unix time after which the requester may refund an unfulfilled job.
    function openJob(
        bytes32 expectArtifactHash,
        address outputAddress,
        address asset,
        uint256 tokenId,
        address agent,
        uint64 expiry
    ) external payable {
        if (expectArtifactHash == bytes32(0) || outputAddress == address(0) || asset == address(0) || agent == address(0))
        {
            revert ZeroArg();
        }
        if (msg.value == 0) revert NoFee();
        if (expiry <= block.timestamp) revert BadExpiry();
        if (spent[expectArtifactHash]) revert AlreadySpent();
        if (jobs[expectArtifactHash].status != Status.None) revert AlreadyExists();

        jobs[expectArtifactHash] = Job({
            requester: msg.sender,
            agent: agent,
            outputAddress: outputAddress,
            asset: asset,
            tokenId: tokenId,
            fee: msg.value,
            expiry: expiry,
            status: Status.Open
        });

        emit JobOpened(expectArtifactHash, msg.sender, agent, outputAddress, asset, tokenId, msg.value, expiry);
    }

    /// @notice Permissionless release. The contract enforces — the caller's identity is irrelevant.
    ///         Releases iff: receipt valid ∧ artifact matches ∧ asset delivered to output_address.
    /// @param receiptProof opaque proof consumed by the configured IReceiptVerifier.
    function release(bytes32 expectArtifactHash, bytes calldata receiptProof) external nonReentrant {
        Job storage j = jobs[expectArtifactHash];
        if (j.status != Status.Open) revert NotOpen();
        if (spent[expectArtifactHash]) revert AlreadySpent();

        // (1)+(2) receipt-validity leg — evidence from the verifier; NEVER sufficient on its own.
        (bool valid, bool artifactHashMatches) = verifier.verify(expectArtifactHash, receiptProof);
        if (!valid) revert ReceiptNotValid();
        if (!artifactHashMatches) revert ArtifactMismatch();

        // (3) on-chain delivery — the trustless teeth. The asset must actually be at output_address now.
        if (IERC721(j.asset).ownerOf(j.tokenId) != j.outputAddress) revert NotDelivered();

        // effects: nullify + close BEFORE paying out (CEI).
        j.status = Status.Released;
        spent[expectArtifactHash] = true;

        (bool ok,) = payable(j.agent).call{value: j.fee}("");
        if (!ok) revert TransferFailed();

        emit Released(expectArtifactHash, j.agent, j.fee, msg.sender);
    }

    /// @notice Reclaim the fee if the job was never fulfilled and has expired. Requester only.
    /// @dev Does NOT set the nullifier — the artifact was never delivered; a fresh attempt simply
    ///      uses a new job_id → a new expectArtifactHash.
    function refund(bytes32 expectArtifactHash) external nonReentrant {
        Job storage j = jobs[expectArtifactHash];
        if (j.status != Status.Open) revert NotOpen();
        if (block.timestamp < j.expiry) revert NotExpired();
        if (msg.sender != j.requester) revert OnlyRequester();

        j.status = Status.Refunded;

        (bool ok,) = payable(j.requester).call{value: j.fee}("");
        if (!ok) revert TransferFailed();

        emit Refunded(expectArtifactHash, j.requester, j.fee);
    }

    /// @notice Convenience view for off-chain readers / the agent UI.
    function getJob(bytes32 expectArtifactHash) external view returns (Job memory) {
        return jobs[expectArtifactHash];
    }
}
