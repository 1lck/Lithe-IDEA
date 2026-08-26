# Platform plugins

Plugin packages are separated by host platform:

- `mac/` contains macOS native plugin packages.
- `win/` contains Windows plugin packages.

Keep manifests, implementation source, platform resources, and focused tests
inside the owning platform tree. Cross-platform plugin contracts and fixtures
belong under the repository-level `shared/` directory.
