# macOS plugins

`Official/` contains the official plugin packages for the macOS product. They
are declarative packages following
[plugin contract v1](../../shared/contracts/plugins/v1/README.md): each package
is a `plugin.json` plus the resources it declares. Lithe reads the declaration,
verifies the package, and launches the declared language server and run/test
processes itself. No plugin code is loaded into the Lithe process, so a package
does not need to be rebuilt for each Lithe release; compatibility is decided by
`pluginAPIVersion`.

| Package | Distribution | Language server |
| --- | --- | --- |
| `JavaSupport` | Bundled in Lithe.app, same Team ID as the host | JDT LS packaged with Lithe |

## Go and PHP moved to Lithe Store

Go Support and PHP Support are no longer official plugins. They are community
plugins in their own repositories and are listed in
[Lithe Store](https://github.com/Lithe-IDEA/Lithe-store):

| Plugin ID | Repository | Language server |
| --- | --- | --- |
| `io.github.lithe-idea.go-support` | [lithe-plugin-go](https://github.com/Lithe-IDEA/lithe-plugin-go) | `gopls` from the user's tools; needs Go |
| `io.github.lithe-idea.php-support` | [lithe-plugin-php](https://github.com/Lithe-IDEA/lithe-plugin-php) | Intelephense installed by the user (`npm install -g intelephense`); needs Node.js |

The PHP plugin does not bundle Intelephense because the Intelephense licence
does not allow redistribution.

The retired official IDs `dev.lithe.plugin.go-support` and
`dev.lithe.plugin.php-support` stay in `OfficialPluginCatalog` so an installed
copy is still verified against its publisher signature. Plugin Management shows
those copies as moved to the community, offers no official update, and asks the
user to uninstall them before installing the community version. Their last
manifests live in `macos/Tests/LitheTests/Fixtures/RetiredOfficialPlugins/` for
tests only.

## Downloadable official plugins

No downloadable official plugin is configured right now:
`Plugins/marketplace/official-plugins.json` and `Plugins/marketplace/index.json`
are empty. The release flow (`scripts/build-official-plugins.sh`,
`scripts/official-plugin-releases.mjs`, and
`.github/workflows/release-official-plugins.yml`) is kept for future official
plugins. A new one gets its own directory under `Official/`, its own tag series
(`plugin-<name>-v<version>`), and an entry in `official-plugins.json`.

A publisher-signed package requires `LITHE_PLUGIN_PACKAGE_PRIVATE_KEY`, a
base64-encoded 32-byte Ed25519 private key whose public key matches the embedded
publisher key; debug builds skip these packages when the key is absent, and a
direct package build fails instead of producing an unsigned package. Keep the
key in a protected file or environment variable and never commit it.

## Local development packages

Plugin authors can test without the publisher key. Build an unsigned
development package with `--development-unsigned`, then install it from disk in
a debug build of Lithe:

```sh
scripts/build-official-plugins.sh --configuration debug \
  --triple arm64-apple-macosx --plugin-id <plugin-id> \
  --development-unsigned --output /tmp/lithe-dev-plugins
```

The package has no `lithe-plugin-signature.json`. Plugin Management records it
as an unsigned development package and replaces it when the same version is
installed again. Release builds of Lithe refuse to load it, and the flag is
rejected for release plugin builds. A package that does contain a signature
document is always verified, whichever way it was installed.

Plugins never delete user tools or project files.
