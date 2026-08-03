# Shared contracts

This directory contains the platform-neutral application contract consumed by the Rust core and both UI implementations.

Suitable content includes:

- command IDs, error codes, and data schemas;
- Git, search, Diff, and project fixtures;
- acceptance scenarios and expected results;
- platform-neutral visual tokens or assets.

The current behavioral contract is documented in [`contracts/application-boundary.md`](contracts/application-boundary.md). Search and Git golden fixtures live under [`fixtures`](fixtures).

Do not place UI state, process management, file watching, terminal sessions, installers, or update logic here. The compiled implementation lives under `rust/lithe-core`; this directory remains the stable contract and fixture source.
