//go:build !dev

package buildinfo

// development is false in a build without the dev tag, such as a packaged release.
const development = false
