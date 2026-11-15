package legacyimport

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
)

// macDomain is the earlier macOS client's user defaults domain (its bundle id).
const macDomain = "app.lithe.desktop"

// maxDefaultsBytes bounds the exported domain read into memory.
const maxDefaultsBytes = 32 << 20

// read exports the domain as an XML property list and lists the installed plugins.
// `defaults export` reads through cfprefsd, so it sees what the earlier client last wrote,
// and changes nothing; a domain that does not exist fails it, which leaves the preferences
// empty.
func read(ctx context.Context) (Found, error) {
	found := Found{Source: macDomain}
	var out bytes.Buffer
	command := exec.CommandContext(ctx, "/usr/bin/defaults", "export", macDomain, "-")
	command.Stdout = &limitedBuffer{buffer: &out, limit: maxDefaultsBytes}
	if err := command.Run(); err == nil {
		values, err := parsePlist(&out)
		if err != nil {
			return Found{}, err
		}
		found = fromDefaults(values)
	} else if ctx.Err() != nil {
		return Found{}, ctx.Err()
	}
	if base, err := os.UserConfigDir(); err == nil {
		found.Plugins = macPlugins(filepath.Join(base, "Lithe", "Plugins"))
	}
	if found.Empty() {
		return Found{}, ErrNotFound
	}
	return found, nil
}
