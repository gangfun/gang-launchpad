// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title TemplateTypes (LaunchpadV3 · economic templates)
/// @notice Shared structs for vault factories / vaults. The schema structs let the CLI, the skill and gang.fun
///         render create params and vault methods generically — no per-template client code.
library TemplateTypes {
    /// @dev `Bps` is a uint16 out of 10_000; `Uint` uses `decimals` for display (18 = ether-style amount).
    enum FieldKind {
        Uint,
        Bps,
        Address,
        Bool,
        String,
        Bytes32
    }

    struct Field {
        string name;
        FieldKind kind;
        uint8 decimals;
        bool isArray;
        string description;
    }

    struct Method {
        string name;
        string description;
        bool isWrite;
        Field[] inputs;
        Field[] outputs;
    }

    struct Metadata {
        string name;
        string version;
        string description;
        string docsURI;
    }

    /// @dev Where a tax payment came from: curve trade (quote taken by the pad) or post-grad pair trade
    ///      (token tax sold to quote by the keeper).
    enum Phase {
        Bonding,
        PostGrad
    }
}
