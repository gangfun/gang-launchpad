// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title TokenURI — the token's metadata JSON URI, fixed at creation
/// @notice Set once from the `metaURI` the creator passed to the pad's `create`: a JSON document (name, symbol,
///         description, image, links) that the CLI builds and uploads. There is no setter. `contractURI()` is ERC-7572;
///         `metaURI()` returns the same value. The logo alone stays in the pad (`logoURIOf`, `Created`).
abstract contract TokenURI {
    string private _uri;

    constructor(string memory uri_) {
        _uri = uri_;
    }

    /// @notice ERC-7572 contract-level metadata URI.
    function contractURI() external view returns (string memory) {
        return _uri;
    }

    function metaURI() external view returns (string memory) {
        return _uri;
    }
}
