# macOS plugins

The macOS product no longer bundles or builds any official plugin. Every
language, build-tool and VCS plugin is a community plugin maintained and
released in its own repository and listed in
[Lithe Store](https://github.com/Lithe-IDEA/Lithe-store). Plugins are
declarative packages following
[plugin contract v1](../../shared/contracts/plugins/v1/README.md); plugin
authors follow [lithe-plugin-docs](https://github.com/Lithe-IDEA/lithe-plugin-docs).

`Plugins/marketplace/index.json` stays as the empty official index that app
packaging embeds; it lists no official plugin.

## Java, Maven and Gradle moved to Lithe Store

Java Support is no longer an official plugin and the app no longer bundles a
JDK or JDT LS. The community plugins bring their own language server and
runtime resources:

| Plugin ID | Repository |
| --- | --- |
| `io.github.lithe-idea.java-support` | [lithe-plugin-java](https://github.com/Lithe-IDEA/lithe-plugin-java) |
| `io.github.lithe-idea.maven-support` | [lithe-plugin-maven](https://github.com/Lithe-IDEA/lithe-plugin-maven) |
| `io.github.lithe-idea.gradle-support` | [lithe-plugin-gradle](https://github.com/Lithe-IDEA/lithe-plugin-gradle) |

The retired official ID `dev.lithe.plugin.java-support` stays in
`OfficialPluginCatalog` as moved to the community, like Go and PHP below.

## Go and PHP moved to Lithe Store

Go Support and PHP Support are no longer official plugins. They are community
plugins in their own repositories:

| Plugin ID | Repository | Language server |
| --- | --- | --- |
| `io.github.lithe-idea.go-support` | [lithe-plugin-go](https://github.com/Lithe-IDEA/lithe-plugin-go) | `gopls` from the user's tools; needs Go |
| `io.github.lithe-idea.php-support` | [lithe-plugin-php](https://github.com/Lithe-IDEA/lithe-plugin-php) | Intelephense installed by the user (`npm install -g intelephense`); needs Node.js |

The PHP plugin does not bundle Intelephense because the Intelephense licence
does not allow redistribution.

The retired official IDs `dev.lithe.plugin.go-support`,
`dev.lithe.plugin.php-support` and `dev.lithe.plugin.java-support` stay in
`OfficialPluginCatalog` so an installed copy is still verified against its
publisher signature. Plugin Management shows those copies as moved to the
community, offers no official update, and asks the user to uninstall them
before installing the community version. The last Go and PHP manifests live in
`macos/Tests/LitheTests/Fixtures/RetiredOfficialPlugins/` for tests only.

## Cargo community plugin

[Cargo](https://github.com/Lithe-IDEA/lithe-plugin-cargo) is maintained and
released independently, alongside the Maven and Gradle community plugins.
It uses API 3 native build windows and a Node SDK metadata provider for
workspace/package build, check, test, clean and binary/example runs, with
Release/Features/Offline options. Cargo and Node are user tools.
See the plugin repository for source, installation, tests and preview releases.
Cargo-specific compatibility tests run in the plugin repository against a pinned
Lithe Core through its public JSON API. This repository retains generic plugin
contract tests; it does not keep Cargo community plugin snapshots.

## Subversion community plugin

[Subversion](https://github.com/Lithe-IDEA/lithe-plugin-svn)
(`io.github.lithe-idea.svn-support`) is a VCS provider plugin maintained and
released independently in the same way. It needs a Lithe build that declares
the `vcsProviders` host capability, and runs the user's `svn` 1.8+ through a
Node SDK provider. Its svn output fixtures and Core compatibility tests live in
the plugin repository. This repository keeps the generic VCS provider contract,
its manifest fixture, and the Core tests; the SDK's sample provider
(`sample-vcs`) lives with the SDK in
[lithe-plugin-docs](https://github.com/Lithe-IDEA/lithe-plugin-docs).

Plugins never delete user tools or project files.
