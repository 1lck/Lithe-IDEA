# Shared contracts

This directory contains the platform-neutral application contract consumed by
the Rust core and both UI implementations. The Rust Core is the authoritative
implementation for commands covered by the contract; platform adapters supply
filesystem, process, terminal, runtime, persistence, and native UI capabilities.

Suitable content includes:

- command IDs, error codes, and data schemas;
- Git, search, Diff, and project fixtures;
- acceptance scenarios and expected results;
- platform-neutral visual tokens or assets.

The current behavioral contract is documented in
[`contracts/application-boundary.md`](contracts/application-boundary.md), and
the JSON/C ABI commands are listed in
[`contracts/rust-core-api.md`](contracts/rust-core-api.md). Search and Git
golden fixtures live under [`fixtures`](fixtures).

Editor syntax roles and fallback semantics are defined by
[`contracts/editor-syntax-theme-v1.schema.json`](contracts/editor-syntax-theme-v1.schema.json).
The canonical Lithe palette lives in
[`fixtures/editor-themes/lithe-v1.json`](fixtures/editor-themes/lithe-v1.json);
platform renderers map the roles to AppKit or Monaco without sharing rendering
implementation.

Update state and preference semantics are defined by
[`contracts/update-v1.md`](contracts/update-v1.md), with the canonical shape in
[`contracts/update-v1.schema.json`](contracts/update-v1.schema.json) and the
golden sample in [`fixtures/updates/update-v1.json`](fixtures/updates/update-v1.json).
Platform installers remain native; their feeds are normalized to this contract
by the macOS and Windows adapters.

Do not place UI state, process management, file watching, terminal sessions, installers, or update logic here. The compiled implementation lives under `rust/lithe-core`; this directory remains the stable contract and fixture source.
