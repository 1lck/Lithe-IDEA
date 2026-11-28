package agents

import (
	"sort"
	"strings"
)

// The bounds agents.start puts on the environment the host gives an agent CLI; a variable
// outside them makes Core refuse the whole start (agents.invalidEnvironment).
const (
	MaxEnvironment      = 256
	maxEnvironmentName  = 256
	maxEnvironmentValue = 32 << 10
)

// LaunchEnvironment is the environment agents.start takes: the variables of base ("NAME=value"
// entries, later ones winning), then overrides. It leaves out what Core would refuse: an empty
// or over-long name, a name holding '=' or NUL, a value over 32 KiB or holding NUL. When more than
// MaxEnvironment remain, every override is kept and base's variables fill the rest in name order.
// It also reports how many variables it left out, which the caller logs as a count only: the
// names and values never leave the process.
func LaunchEnvironment(base []string, overrides map[string]string) (map[string]string, int) {
	usable := func(name, value string) bool {
		return name != "" && len(name) <= maxEnvironmentName && !strings.ContainsAny(name, "=\x00") &&
			len(value) <= maxEnvironmentValue && !strings.ContainsRune(value, 0)
	}
	dropped := 0
	from := map[string]string{}
	for _, entry := range base {
		name, value, ok := strings.Cut(entry, "=")
		if !ok || !usable(name, value) {
			dropped++
			continue
		}
		if _, seen := from[name]; seen {
			// A later entry of the same name wins, as it does in a process environment.
			dropped++
		}
		from[name] = value
	}
	out := make(map[string]string, MaxEnvironment)
	for name, value := range overrides {
		if !usable(name, value) || len(out) >= MaxEnvironment {
			dropped++
			continue
		}
		if _, shadowed := from[name]; shadowed {
			delete(from, name)
		}
		out[name] = value
	}
	names := make([]string, 0, len(from))
	for name := range from {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		if len(out) >= MaxEnvironment {
			dropped++
			continue
		}
		out[name] = from[name]
	}
	return out, dropped
}
