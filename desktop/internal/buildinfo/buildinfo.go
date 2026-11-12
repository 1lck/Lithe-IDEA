// Package buildinfo tells a development build from a release one.
package buildinfo

// Development reports whether this binary has the dev build tag. The build
// target in desktop/Makefile supplies the tag; packaged releases omit it.
const Development = development
