# Web preview third-party notices

The preview pages and every script, style and font they use are embedded in the Lithe binary and
served to the page from its own `lithe-preview` origin. The pages load nothing from a CDN or any other
network address, and nothing here is downloaded, generated or modified at runtime.

- Highlight.js 11.5.1 — BSD-3-Clause — `vendor/highlight-LICENSE`
- KaTeX 0.16.0 and its fonts — MIT — `vendor/katex-LICENSE`
- KaTeX 0.16.0 mhchem extension (mhchem 3.3.0 adaptation) — MIT / upstream Apache-2.0 notice — `vendor/mhchem-NOTICE`
- Mermaid 11.14.0 — MIT — `vendor/mermaid-LICENSE`
- D3 6.7.0 — ISC — `vendor/d3-LICENSE`
- markmap-lib 0.14.1 — MIT — `vendor/markmap-lib-LICENSE`
- markmap-view 0.14.0 — MIT — `vendor/markmap-view-LICENSE`

The Highlight.js browser bundle is the distribution already vendored by MiaoYan; its version banner and
upstream license are preserved. The remaining files come from the matching npm distributions.

`vendor/mhchem.min.js` comes from `https://registry.npmjs.org/katex/-/katex-0.16.0.tgz`
(`package/dist/contrib/mhchem.min.js`), matching the bundled KaTeX runtime. The archive is verified with
npm's SHA-512 integrity
`sha512-wPRB4iUPysfH97wTgG5/tRLYxmKVq6Q4jRAWRVOUxXB1dsiv4cvcNjqabHkrOvJHM1Bpk3WrgmllSO1vIvP24w==`; the
extracted file's SHA-256 is `5c0a121a8b490afc85860a522347aeb34fb508c6b23044e5d29f6b2194227b51`. The
source copyright and adaptation notice are preserved separately because the minified distribution omits
that header.

The pages load a library only when the document uses it: KaTeX for math, Highlight.js for code blocks,
Mermaid for `mermaid` blocks, and D3 with markmap for `markmap` blocks.
