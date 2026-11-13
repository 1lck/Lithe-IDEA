// Package contractfixture locates the contract files that tests read. The plugin contract
// (shared/plugins/contract/v1/) and the application fixtures (rust/fixtures/) each have a single
// source in the Lithe-core-rust checkout this client links, and this repository keeps no copy.
// scripts/desktop/desktop-go.sh exports LITHE_PLUGIN_CONTRACT_DIR and LITHE_CORE_FIXTURE_DIR for
// the same checkout it builds: the pinned clone, or LITHE_CORE_RUST_DIR when that is set.
package contractfixture

import (
	"os"
	"path/filepath"
)

// EnvironmentVariable names the plugin contract directory of the linked Lithe-core-rust checkout.
const EnvironmentVariable = "LITHE_PLUGIN_CONTRACT_DIR"

// CoreFixtureEnvironmentVariable names the rust/fixtures directory of the linked Lithe-core-rust
// checkout.
const CoreFixtureEnvironmentVariable = "LITHE_CORE_FIXTURE_DIR"

// Path returns rel inside the plugin contract directory, for example
// "fixtures/backend/backend.plugin.json". It panics when the variable is unset, because a test
// that silently read nothing would pass without checking the contract; run Go through
// scripts/desktop/desktop-go.sh instead.
func Path(rel string) string {
	return join(EnvironmentVariable, rel)
}

// CoreFixture returns rel inside the Core fixture directory, for example
// "git/status-porcelain-v2.json". It panics when the variable is unset, for the same reason as
// Path.
func CoreFixture(rel string) string {
	return join(CoreFixtureEnvironmentVariable, rel)
}

func join(variable, rel string) string {
	dir := os.Getenv(variable)
	if dir == "" {
		panic(variable + " is not set; run Go through scripts/desktop/desktop-go.sh")
	}
	return filepath.Join(dir, filepath.FromSlash(rel))
}
