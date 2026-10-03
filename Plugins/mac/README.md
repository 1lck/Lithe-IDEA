# macOS plugins

`Official/` contains the native plugin packages released with the macOS
product. Each package owns its manifest, Bundle metadata, Swift source, and
focused tests.

## Optional PHP Support

PHP Support is built separately and is not included in Lithe.app. Build it after
building the host API for the same configuration and architecture:

```sh
LITHE_CODESIGN_IDENTITY="<same signing identity as host>" \
LITHE_PLUGIN_PACKAGE_PRIVATE_KEY="$(cat /secure/path/lithe-plugin-package-private-key.base64)" \
  scripts/build-official-plugins.sh --configuration release \
  --triple arm64-apple-macosx --plugin-id dev.lithe.plugin.php-support
```

Use `x86_64-apple-macosx` for Intel. Keep the resulting
`dev.lithe.plugin.php-support` directory intact for offline recovery; normal
users download, install, reinstall, and uninstall PHP Support from Plugin
Management. After installation and restart, the LSP settings page only controls
the current project's PHP language server. Native package verification still
requires the host's signing team. A PHP package also requires
`LITHE_PLUGIN_PACKAGE_PRIVATE_KEY`, a base64-encoded 32-byte Ed25519 private key
whose public key matches the embedded publisher key; debug builds skip PHP when
the key is absent, and a direct PHP package build fails instead of producing an
unsigned package. Keep the key in a protected file or environment variable and
never commit it.

The PHP plugin archive carries a pinned Intelephense package described by
`language-server.json`. Plugin Management downloads and verifies that tool as
part of the plugin package, stores it under the user-level plugin directory,
and removes it with the plugin. Node.js is still required at runtime because
Intelephense is distributed as a Node.js program. Install PHP/Composer and
project PHPUnit only when using run/test. The plugin never deletes those user
tools or project files.
