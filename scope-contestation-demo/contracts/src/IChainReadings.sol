// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @title IChainReadings — a chain-native, historically-addressable readings source (type-1).
/// @notice Returns a declared source's reading as of a given block. A production reader is a
///         historical-aware on-chain oracle (round/block-keyed, e.g. Chainlink-style); the value at a
///         PINNED past block is immutable, which is exactly what gives the type-1 value-fidelity leg its
///         pre-outcome property WITHOUT a separate value commitment — the chain at the pinned block is
///         itself the commitment.
interface IChainReadings {
    /// @param sourceId    the declared coordinate id (keccak256 of the source descriptor)
    /// @param blockNumber the pinned (pre-outcome) block the reading is taken at
    /// @return option     the source's categorical reading at that block (same enum as Vote.option)
    function valueAt(bytes32 sourceId, uint256 blockNumber) external view returns (uint8 option);
}
