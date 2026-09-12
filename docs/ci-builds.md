# CI builds and test downloads

macOS CI and Windows CI upload complete test packages whenever their product
build lane is selected. Open the workflow run's **Summary** and use the
**macOS test download** or **Windows x64 test download** link. The same files
appear in the run's **Artifacts** list.

- macOS PRs produce separate Apple Silicon (`arm64`) and Intel (`x86_64`) DMGs.
  The two jobs run concurrently when runners are available.
- macOS pushes to `main` and manual runs verify the default universal package,
  then assemble a universal DMG with the real Java tools using the same compiled
  outputs. The packaging smoke test's temporary Java fixtures are never uploaded.
- Windows produces an NSIS `.exe` installer. Packaging performs the Release
  build and frontend type check once; there is no preceding `--no-bundle` build.
- Each package includes a SHA-256 checksum and the bundled Java tools. macOS
  apps are ad-hoc signed, and Windows CI installers are unsigned.
- Artifact links require GitHub sign-in and expire after 14 days. Downloading
  an artifact gives a ZIP containing the installer and checksum. The archive
  uses compression level 0 because DMGs and NSIS installers are already compressed.

The summary records the exact checked-out revision. For a pull request this is
normally GitHub's test merge commit. An artifact can become available before
the remaining jobs finish, so check **macOS CI gate** or **Windows CI gate** for
the combined test result. A failed architecture still fails the macOS gate;
`fail-fast: false` lets the other architecture finish and upload its package.
Documentation-only changes can skip packaging. To request a complete validation
and package for a branch, select **Run workflow** in the corresponding CI workflow.

The GitHub CLI can also download a particular run's packages:

```bash
gh run download <run-id> --repo 1lck/Lithe-IDEA --pattern 'Lithe-macos-*'
gh run download <run-id> --repo 1lck/Lithe-IDEA --pattern 'Lithe-windows-x64-*'
```

Rolling previews also have public, stable download URLs after publication:

- [Apple Silicon preview DMG](https://github.com/1lck/Lithe-IDEA/releases/download/preview-0.3.0/Lithe-0.3.0-arm64.dmg)
- [Intel preview DMG](https://github.com/1lck/Lithe-IDEA/releases/download/preview-0.3.0/Lithe-0.3.0-x86_64.dmg)
- [Windows x64 preview installer](https://github.com/1lck/Lithe-IDEA/releases/download/preview-0.3.0/Lithe-0.3.0-windows-x64.exe)

These URLs follow the current `PREVIEW_TAG` and `PREVIEW_VERSION` in the preview
workflows. They identify the latest published preview, rather than an arbitrary
PR. macOS preview jobs additionally expose their own artifact links before the
combined rolling Release publishes.

## Build time and caches

The September 12, 2026 investigation found two separate sources of delay:

| Observed run | Total elapsed | Main cost |
| --- | --- | --- |
| [macOS CI 34677881176](https://github.com/1lck/Lithe-IDEA/actions/runs/34677881176) | 37m 25s | Universal packaging 34m 37s; Swift tests ran concurrently and finished in about 10m |
| [macOS CI 34667794413](https://github.com/1lck/Lithe-IDEA/actions/runs/34667794413) | 43m 52s | Packaging job started about 10m after the run began, then ran for about 34m |
| [macOS Preview 34577516401](https://github.com/1lck/Lithe-IDEA/actions/runs/34577516401) | 54m 03s | Intel job started about 32m after source preparation, then ran for about 20m |

The first CI run compiled the Swift product twice (about 11m 27s and 9m 54s)
and spent another 12m compiling Rust Core and database helpers. Download caches
were already hitting, but macOS had no cache for compiled Rust dependencies.

The macOS package CI and preview workflows now cache Cargo fingerprints, build
script outputs, and dependency outputs for both `rust/target/macos` (Core) and
`rust/target` (database helpers). Keys include runner architecture, compiler,
Xcode/SDK/macOS versions, build flags, dependency manifests, and build scripts.
An architecture-specific job can restore the universal cache from its base
branch. Final executables are not cached; Cargo still runs before packaging.
An interrupted cache restore is discarded, leaving the existing verified
download cache as the fallback. Swift compilation products are not cached.

Cold builds, compiler changes, and dependency changes still require compilation.
PR concurrency shortens the serial build path without promising the same
reduction in total runner minutes. It also needs two available macOS runners.
GitHub queue delays remain outside these build steps. Compare warm-cache runs
with these baselines before claiming a measured improvement. A runner pool
change should be evaluated separately if queueing continues to dominate.

The artifact behavior and compression setting follow
[actions/upload-artifact](https://github.com/actions/upload-artifact), and cache
reuse follows GitHub's
[branch access restrictions](https://docs.github.com/en/actions/reference/workflows-and-actions/dependency-caching).
