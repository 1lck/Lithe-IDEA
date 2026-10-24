# Platform plugins

Plugin packages are separated by host platform:

- `mac/` contains macOS native plugin packages.
- `win/` contains Windows plugin packages.

Keep manifests, implementation source, platform resources, and focused tests
inside the owning platform tree. Cross-platform plugin contracts and fixtures
belong under the repository-level `shared/` directory.

Community plugins live in their own repositories and never need a change here.
Their authors start at
[lithe-plugin-docs](https://github.com/Lithe-IDEA/lithe-plugin-docs), which has
the developer guide, tutorials, a pinned copy of the whole plugin contract, and
the official plugin backend SDKs.
