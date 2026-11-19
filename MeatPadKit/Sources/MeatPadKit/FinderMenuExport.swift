// The Finder menu model lives in its own small module so the sandboxed Finder Sync extension
// can link it without the rest of MeatPadKit (tree-sitter grammars, the LSP client). The app
// keeps a single `import MeatPadKit`.
@_exported import FinderMenuKit
