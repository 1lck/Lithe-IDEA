package desktop

import (
	_ "embed"
	"strings"
)

//go:embed viva.toml
var vivaManifest string

// Version returns the version declared by the [app] table in viva.toml.
func Version() string {
	inApp := false
	for _, line := range strings.Split(vivaManifest, "\n") {
		line = strings.TrimSpace(line)
		if line == "[app]" {
			inApp = true
			continue
		}
		if strings.HasPrefix(line, "[") {
			inApp = false
			continue
		}
		if !inApp {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok || strings.TrimSpace(key) != "version" {
			continue
		}
		value = strings.TrimSpace(value)
		if len(value) >= 2 && value[0] == '"' && value[len(value)-1] == '"' {
			return value[1 : len(value)-1]
		}
	}
	panic("desktop: viva.toml has no quoted version in its [app] table")
}
