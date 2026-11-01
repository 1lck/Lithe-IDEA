# Markdown preview third-party notices

All preview dependencies are bundled with Lithe and loaded from the application resource bundle. The runtime does not load scripts, styles, or fonts from a CDN.

- Highlight.js 11.5.1 — BSD-3-Clause — `vendor/highlight-LICENSE`
- KaTeX 0.16.0 and its fonts — MIT — `vendor/katex-LICENSE`
- KaTeX 0.16.0 mhchem extension (mhchem 3.3.0 adaptation) — MIT / upstream Apache-2.0 notice — `vendor/mhchem-NOTICE`
- Mermaid 11.14.0 — MIT — `vendor/mermaid-LICENSE`
- D3 6.7.0 — ISC — `vendor/d3-LICENSE`
- markmap-lib 0.14.1 — MIT — `vendor/markmap-lib-LICENSE`
- markmap-view 0.14.0 — MIT — `vendor/markmap-view-LICENSE`

The Highlight.js browser bundle is the distribution already vendored by MiaoYan; its version banner and upstream license are preserved. The remaining files come from the matching npm distributions. PlantUML and its encoder are intentionally not included.

`vendor/mhchem.min.js` comes from `https://registry.npmjs.org/katex/-/katex-0.16.0.tgz` (`package/dist/contrib/mhchem.min.js`), matching the bundled KaTeX runtime. The archive is verified with npm's SHA-512 integrity `sha512-wPRB4iUPysfH97wTgG5/tRLYxmKVq6Q4jRAWRVOUxXB1dsiv4cvcNjqabHkrOvJHM1Bpk3WrgmllSO1vIvP24w==`; the extracted file's SHA-256 is `5c0a121a8b490afc85860a522347aeb34fb508c6b23044e5d29f6b2194227b51`. The source copyright and adaptation notice are preserved separately because the minified distribution omits that header. This is a checked-in build input, never downloaded or modified at runtime.
