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
| `GoSupport` | Downloaded from Plugin Management, publisher-signed | `gopls` from the user's tools; needs Go |
| `PhpSupport` | Downloaded from Plugin Management, publisher-signed | Intelephense packaged in the plugin; needs Node.js |

No official plugin is bundled in Lithe.app. Both packages are released through
their own tag series (`plugin-go-support-v<version>`,
`plugin-php-support-v<version>`) and listed in the official marketplace index;
see `Plugins/marketplace/official-plugins.json`.

Packages are architecture-neutral. `--triple` only selects the SwiftPM layout
for the default output directory and the package signer.

## Building a downloadable plugin

Official plugins are built separately and are not included in Lithe.app. PHP
Support is the example below; pass `dev.lithe.plugin.go-support` to build Go
Support the same way (it packages only `plugin.json`, so no language-server
download happens):

```sh
LITHE_PLUGIN_PACKAGE_PRIVATE_KEY="$(cat /secure/path/lithe-plugin-package-private-key.base64)" \
  scripts/build-official-plugins.sh --configuration release \
  --triple arm64-apple-macosx --plugin-id dev.lithe.plugin.php-support
```

The build downloads the Intelephense archive pinned by `language-server.json`,
verifies its SHA-256, and assembles it under `language-server/` in the package
before signing. Keep the resulting `dev.lithe.plugin.php-support` directory
intact for offline recovery; normal users download, install, reinstall, and
uninstall them from Plugin Management. A publisher-signed package requires
`LITHE_PLUGIN_PACKAGE_PRIVATE_KEY`, a base64-encoded 32-byte Ed25519 private key
whose public key matches the embedded publisher key; debug builds skip these
packages when the key is absent, and a direct package build fails instead of
producing an unsigned package. Keep the key in a protected file or environment variable and
never commit it.

Users who installed the retired native PHP package (0.3.0) see "Update required"
in Plugin Management. Lithe no longer loads that package; Download and Install
replaces it with the declarative package and keeps the user's enablement.

## Local development packages

Plugin authors can test without the publisher key. Build an unsigned
development package, then install it from disk in a debug build of Lithe:

```sh
scripts/build-official-plugins.sh --configuration debug \
  --triple arm64-apple-macosx --plugin-id dev.lithe.plugin.php-support \
  --development-unsigned --output /tmp/lithe-dev-plugins
```

The package has no `lithe-plugin-signature.json`. Plugin Management records it
as an unsigned development package and replaces it when the same version is
installed again. Release builds of Lithe refuse to load it, and the flag is
rejected for release plugin builds. A package that does contain a signature
document is always verified, whichever way it was installed.

Node.js is required at runtime because Intelephense is a Node.js program; Lithe
discovers it and passes it as `LITHE_NODE_PATH`. Install PHP/Composer and project
PHPUnit only when using run/test. Plugins never delete those user tools or
project files.
