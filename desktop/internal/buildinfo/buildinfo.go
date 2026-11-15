// Package buildinfo tells a development build from a packaged one, and a stable release from
// a preview.
package buildinfo

// Development reports whether this binary has the dev build tag. The build
// target in desktop/Makefile supplies the tag; packaged releases omit it.
const Development = development

// Stable reports whether this binary is a stable release: one packaged from the commit that
// carries its release tag, desktop-v<version> with the version in desktop/viva.toml.
// scripts/desktop/package-desktop.sh adds the lithe_stable build tag only then. Every other
// build, the daily AutoBuild, a local package or a development build, is a preview, and Lithe
// says so next to the version.
const Stable = stable
