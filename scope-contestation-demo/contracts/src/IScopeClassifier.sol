// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.0;

// Layer 2 interface — verbatim from JimmyShi22's spec (gist 8ef5b25f…), the seam
// our Layer 1 verifyAbsence leg hands off to. Reproduced here so the integration
// test can wire the full contest() path end-to-end.
interface IScopeClassifier {

    /// @notice Emitted on every classify() call — passing and failing.
    ///         Carries the classificationDigest preimage for independent verification.
    event ClassificationCompleted(
        bytes32 indexed taskId,
        bytes32 indexed coordinateHash,
        bytes32 indexed classificationDigest,
        bool    separated,
        bytes32 paramsHash,  // keccak256(params)
        bytes32 aHash,       // keccak256(a)
        bytes32 bHash,       // keccak256(b)
        uint256 timestamp
    );

    /// @notice Run the committed w on witness pair (a, b).
    /// @return separated            false = w(a) == w(b); X is not needed.
    ///                              true  = w(a) != w(b); X IS material.
    /// @return classificationDigest Commitment to this classification event.
    function classify(
        bytes32        taskId,
        bytes32        coordinateHash,
        bytes calldata params,
        bytes calldata a,
        bytes calldata b
    ) external returns (bool separated, bytes32 classificationDigest);

    /// @notice Classifier paradigm in "{type}/{variant}" format.
    function classifierType() external view returns (string memory);
}
