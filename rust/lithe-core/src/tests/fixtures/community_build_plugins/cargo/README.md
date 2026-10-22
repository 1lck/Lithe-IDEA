# Cargo plugin compatibility snapshot

Source: https://github.com/Lithe-IDEA/lithe-plugin-cargo

Revision: `7dfdd2bcf49e77c701cad1a41bea1f2abcdeca0c` (0.1.0 preview).

`plugin.json` is the distributable manifest. `model.json` is the integration
golden checked against real Cargo metadata for the plugin repository’s
`test/fixtures/workspace`. The Core test adds the SDK’s format/version envelope.

Refresh both files from the same reviewed plugin revision, update this provenance,
then run `cargo test --manifest-path rust/Cargo.toml -p lithe-core --lib cargo_plugin`.
The main repository does not assemble or download the Cargo plugin.
