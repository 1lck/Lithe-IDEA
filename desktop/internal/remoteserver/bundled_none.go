//go:build !lithe_bundled_remote_server

package remoteserver

// bundled returns no builds: a development build runs without the packaging step, and uses the
// stage StageEnv names instead.
func bundled() *source { return nil }
