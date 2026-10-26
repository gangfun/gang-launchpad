// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title TokenURI — the token's metadata URI, fixed at creation
/// @notice Set once from the `logoURI` the creator passed to the pad's `create` (the same string the pad keeps in
///         `logoURIOf` and emits in `Created`); there is no setter. `contractURI()` is ERC-7572; `metaURI()` returns
///         the same value.
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
