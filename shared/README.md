# Shared contracts

This directory is for the small, platform-neutral part of Lithe. Share behavior and test inputs before sharing runtime code.

Suitable content includes:

- command IDs, error codes, and data schemas;
- Git, search, Diff, and project fixtures;
- acceptance scenarios and expected results;
- platform-neutral visual tokens or assets.

The current behavioral contract is documented in [`contracts/application-boundary.md`](contracts/application-boundary.md). Search and Git golden fixtures live under [`fixtures`](fixtures).

Do not place UI state, process management, file watching, terminal sessions, installers, or update logic here. A compiled shared library requires a separate architecture review and measured benefit on both platforms.
