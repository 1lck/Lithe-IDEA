//go:build !windows

package pluginservice

// encodeArgumentFile is the argument file as the launcher reads it: the JDK launchers of
// macOS and Linux read UTF-8.
func encodeArgumentFile(text string) ([]byte, error) {
	return []byte(text), nil
}
