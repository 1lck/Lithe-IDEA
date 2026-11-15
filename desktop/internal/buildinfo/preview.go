//go:build !lithe_stable

package buildinfo

// stable is false in a build that was not packaged from its release tag.
const stable = false
