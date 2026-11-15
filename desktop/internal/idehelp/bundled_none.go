//go:build !lithe_bundled_helper

package idehelp

// bundled returns no bytes: a development build runs without the packaging step, and the
// settings page reports the helper as missing until one is provided.
func bundled() []byte { return nil }
