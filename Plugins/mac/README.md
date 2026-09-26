# macOS plugins

`Official/` contains the native plugin packages released with the macOS
product. Each package owns its manifest, Bundle metadata, Swift source, and
focused tests.

## Optional PHP Support

PHP Support is built separately and is not included in Lithe.app. Build it after
building the host API for the same configuration and architecture:

```sh
LITHE_CODESIGN_IDENTITY="<same signing identity as host>" \
  scripts/build-official-plugins.sh --configuration release \
  --triple arm64-apple-macosx --plugin-id dev.lithe.plugin.php-support
```

Use `x86_64-apple-macosx` for Intel. Distribute the resulting
`dev.lithe.plugin.php-support` directory intact; users select that directory in
Plugin Management → Install, then enable PHP Language Server / PHP Execution.
Native package verification still requires the host's signing team. Debug/ad-hoc
CI packages are for testing and are not production distribution artifacts.

Configure a user-installed Intelephense executable in Language Server settings
(Node.js is required). Install PHP/Composer and project PHPUnit only when using
run/test. Uninstalling the plugin does not delete user tools or project files.
