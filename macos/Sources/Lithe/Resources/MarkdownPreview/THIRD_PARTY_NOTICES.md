# Markdown preview third-party notices

All preview dependencies are bundled with Lithe and loaded from the application resource bundle. The runtime does not load scripts, styles, or fonts from a CDN.

- Highlight.js 11.5.1 — BSD-3-Clause — `vendor/highlight-LICENSE`
- KaTeX 0.16.0 and its fonts — MIT — `vendor/katex-LICENSE`
- KaTeX 0.16.0 mhchem extension (mhchem 3.3.0 adaptation) — MIT / upstream Apache-2.0 notice — `vendor/mhchem-NOTICE`
- Mermaid 11.14.0 — MIT — `vendor/mermaid-LICENSE`
- D3 6.7.0 — ISC — `vendor/d3-LICENSE`
- markmap-lib 0.14.1 — MIT — `vendor/markmap-lib-LICENSE`
- markmap-view 0.14.0 — MIT — `vendor/markmap-view-LICENSE`
- PlantUML JavaScript engine `@plantuml/core` 1.2026.9 — MIT — `vendor/plantuml/LICENSE`

The Highlight.js browser bundle is the distribution already vendored by MiaoYan; its version banner and upstream license are preserved. The remaining files come from the matching npm distributions.

`vendor/mhchem.min.js` comes from `https://registry.npmjs.org/katex/-/katex-0.16.0.tgz` (`package/dist/contrib/mhchem.min.js`), matching the bundled KaTeX runtime. The archive is verified with npm's SHA-512 integrity `sha512-wPRB4iUPysfH97wTgG5/tRLYxmKVq6Q4jRAWRVOUxXB1dsiv4cvcNjqabHkrOvJHM1Bpk3WrgmllSO1vIvP24w==`; the extracted file's SHA-256 is `5c0a121a8b490afc85860a522347aeb34fb508c6b23044e5d29f6b2194227b51`. The source copyright and adaptation notice are preserved separately because the minified distribution omits that header. This is a checked-in build input, never downloaded or modified at runtime.

PlantUML uses the official JavaScript build's built-in Smetana layout engine. Graphviz/Viz.js, the URL encoder, optional standard libraries, themes, emoji and external include loaders are not bundled. Rendering is local in a nonpersistent, restricted WebView; the result is displayed as an SVG image, never injected into the document DOM.

`vendor/plantuml/plantuml.js` comes unchanged from `https://registry.npmjs.org/@plantuml/core/-/core-1.2026.9.tgz` (`package/plantuml.js`, upstream Git revision `18d0aae311a4f1eb3723bb4b0ad939185e22f166`). npm archive integrity: `sha512-Qy46og9hEb+wOFtjUfniWkl/BDwHpDuebQX5rF+35s9PS2G4cKZf1iWw4E/ELLQ0pTkESPDoQTbKWcc3ZyVcVA==`. Script SHA-256: `21c049ce47d087eff61ae0836f9c62a2b0c0d2528a5f16c2247057544228fae7`. The npm release's MIT license and upstream notices are preserved in `vendor/plantuml/LICENSE` (line endings normalized to LF only). Versions before 1.2026.6 use different licensing and must not be substituted. These are Git-tracked build inputs, not runtime downloads or writable bundle state.
