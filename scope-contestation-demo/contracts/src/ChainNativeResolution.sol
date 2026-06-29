// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IResolutionCommitment} from "./IResolutionCommitment.sol";
import {IChainReadings} from "./IChainReadings.sol";
import {Vote} from "./ScopeTypes.sol";

/// @title ChainNativeResolution — type-1 (chain-native) reference impl of the value-fidelity leg.
///
/// @notice The second reference impl of {IResolutionCommitment.verifyValueFidelity}, paired with the
///         type-2 {ResolutionCommitment}. Same pluggable interface, same verdict guarantee ("X was
///         material to THE resolution"); the difference is purely WHERE the readings live and therefore
///         HOW value-fidelity is proven:
///
///           type-2 (off-chain): chain can't recompute the readings, so `a` is checked against a
///                   pre-outcome resolutionRoot commitment (keccak of the sorted (id,value) leaves).
///           type-1 (chain-native, THIS impl): the readings ARE on-chain, so there is no value
///                   commitment to carry — verifyValueFidelity RECOMPUTES each declared source's value
///                   from its on-chain reading at a pinned block and requires it equals `a`'s value.
///
///         This is the recompute analog of {ScopeContestation.verifyAbsence} ↔ verifyScopeComplete:
///         instead of committing then comparing, it re-derives from public data and requires a match.
///
/// PRE-OUTCOME MUST (inherited): satisfied structurally. The (reader, blockPin) pair is committed
///         pre-outcome via {commitChainSource}; the chain state at a pinned past block is immutable, so a
///         committer cannot fudge values after seeing the outcome — the chain at `blockPin` IS the
///         pre-outcome record. (`blockPin` is required to be a block that already exists at commit time.)
///         Damon's note holds: the block pin lives in the commitment on the impl side, so the
///         {IResolutionCommitment} interface — and therefore `verifyValueFidelity(scopeId, a)` — does not
///         fork between the two impls.
///
/// @dev    `valueAt(sourceId, blockNumber)` must read the source as of the pinned block; a real reader is
///         a historical/round-addressable oracle. Per-pair comparison is order-independent, so no sort is
///         needed here (unlike the type-2 root recompute). Source-authentication (zkTLS / input-provenance)
///         is ORTHOGONAL and only relevant to type-2 — for chain-native readings the chain is the source.
contract ChainNativeResolution is IResolutionCommitment {
    struct Source {
        IChainReadings reader;
        uint256 blockPin;
        bool set;
    }

    mapping(bytes32 => Source) private _src;    // scopeId → pinned chain source
    mapping(bytes32 => bytes32) private _roots; // scopeId → keccak(reader, blockPin) (the binding)

    event ChainSourceCommitted(bytes32 indexed scopeId, address reader, uint256 blockPin);

    /// @notice Type-1 pre-outcome commit: pin the on-chain readings source + the block to recompute at.
    ///         The analog of type-2's commitResolution; MUST be called before the outcome is observable.
    function commitChainSource(bytes32 scopeId, IChainReadings reader, uint256 blockPin) external {
        require(!_src[scopeId].set, "source already committed");
        require(address(reader) != address(0), "empty reader");
        require(blockPin <= block.number, "blockPin not yet mined"); // a real, already-mined (pre-outcome) block
        _src[scopeId] = Source({reader: reader, blockPin: blockPin, set: true});
        _roots[scopeId] = keccak256(abi.encode(address(reader), blockPin));
        emit ChainSourceCommitted(scopeId, address(reader), blockPin);
    }

    /// @inheritdoc IResolutionCommitment
    /// @dev The chain-native impl pins a SOURCE, not a value root, so this interface method is not the
    ///      commit path — use {commitChainSource}. Reverts rather than silently no-op so a mis-wired
    ///      deployment fails loudly instead of leaving value-fidelity uncommitted.
    function commitResolution(bytes32, bytes32) external pure {
        revert("ChainNativeResolution: use commitChainSource(scopeId, reader, blockPin)");
    }

    /// @inheritdoc IResolutionCommitment
    function resolutionRootOf(bytes32 scopeId) external view returns (bytes32) {
        return _roots[scopeId];
    }

    /// @inheritdoc IResolutionCommitment
    /// @notice Recompute each declared source's value from chain at the pinned block and require it equals
    ///         `a`'s claimed value. `a`'s sourceIds were already validated against scopeRoot by
    ///         verifyScopeComplete, so this leg only has to pin the VALUES — and the chain pins them.
    function verifyValueFidelity(bytes32 scopeId, bytes calldata a)
        external
        view
        returns (bool)
    {
        Source memory s = _src[scopeId];
        if (!s.set) return false; // no chain source committed

        Vote[] memory va = abi.decode(a, (Vote[]));
        uint256 n = va.length;
        if (n == 0) return false;

        for (uint256 i = 0; i < n; i++) {
            // recompute from public chain state at the pinned, pre-outcome block
            if (s.reader.valueAt(va[i].sourceId, s.blockPin) != va[i].option) return false;
        }
        return true;
    }

    /// @inheritdoc IResolutionCommitment
    /// @notice GUARD 7 (type-1): recompute the contested coordinate's value from the pinned
    ///         chain source — identical machinery to verifyValueFidelity, pointed at one key.
    function verifyCoordinateValue(bytes32 scopeId, bytes32 key, bytes calldata value)
        external
        view
        returns (bool)
    {
        Source memory s = _src[scopeId];
        if (!s.set) return false;                       // no chain source committed
        uint8 claimed = abi.decode(value, (uint8));     // X's claimed option
        return s.reader.valueAt(key, s.blockPin) == claimed;
    }
}
