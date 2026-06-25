// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IScopeClassifier} from "./IScopeClassifier.sol";
import {Vote} from "./ScopeTypes.sol";

/// @title MajorityClassifier — Layer 2 "categorical/majority" reference (Jimmy's leg)
/// @notice Plurality vote with a quorum threshold. Stateless: all config rides in
///         `params = abi.encode(uint256 minSamples, uint256 quorumBps)`. One deployed
///         classifier serves any number of markets. Included here only so the
///         integration test can run a real w(a) vs w(b) — the canonical classifiers
///         are JimmyShi22's.
contract MajorityClassifier is IScopeClassifier {
    uint256 private constant NO_QUORUM = type(uint256).max;

    function classifierType() external pure returns (string memory) {
        return "categorical/majority";
    }

    function classify(
        bytes32 taskId,
        bytes32 coordinateHash,
        bytes calldata params,
        bytes calldata a,
        bytes calldata b
    ) external returns (bool separated, bytes32 classificationDigest) {
        (uint256 minSamples, uint256 quorumBps) = abi.decode(params, (uint256, uint256));
        Vote[] memory vb = abi.decode(b, (Vote[]));
        require(vb.length >= minSamples, "minSamples");

        uint256 wa = _plurality(a, quorumBps);
        uint256 wb = _plurality(b, quorumBps);
        separated = wa != wb; // w(a) != w(b) → X is material

        classificationDigest = keccak256(
            abi.encode(
                taskId,
                coordinateHash,
                keccak256(params),
                keccak256(a),
                keccak256(b),
                separated,
                block.timestamp
            )
        );
        emit ClassificationCompleted(
            taskId,
            coordinateHash,
            classificationDigest,
            separated,
            keccak256(params),
            keccak256(a),
            keccak256(b),
            block.timestamp
        );
    }

    /// @dev plurality winner if it clears quorum; NO_QUORUM on empty / tie / below-quorum.
    function _plurality(bytes calldata enc, uint256 quorumBps) private pure returns (uint256) {
        Vote[] memory v = abi.decode(enc, (Vote[]));
        uint256 total = v.length;
        if (total == 0) return NO_QUORUM;

        uint256[256] memory counts;
        for (uint256 i = 0; i < total; i++) counts[v[i].option]++;

        uint256 best = 0;
        uint256 bestC = 0;
        bool tie = false;
        for (uint256 o = 0; o < 256; o++) {
            if (counts[o] > bestC) {
                bestC = counts[o];
                best = o;
                tie = false;
            } else if (counts[o] == bestC && bestC > 0) {
                tie = true;
            }
        }
        if (tie) return NO_QUORUM;
        if (bestC * 10000 < total * quorumBps) return NO_QUORUM;
        return best;
    }
}
