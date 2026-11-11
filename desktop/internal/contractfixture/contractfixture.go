// Package contractfixture locates the plugin contract that tests read. The contract has a single
// source, shared/plugins/contract/v1/ of the Lithe-core-rust checkout this client links, and this
// repository keeps no copy. scripts/desktop/desktop-go.sh exports LITHE_PLUGIN_CONTRACT_DIR for
// the same checkout it builds: the pinned clone, or LITHE_CORE_RUST_DIR when that is set.
package contractfixture

import (
	"os"
	"path/filepath"
)

// EnvironmentVariable names the contract directory of the linked Lithe-core-rust checkout.
const EnvironmentVariable = "LITHE_PLUGIN_CONTRACT_DIR"

// Path returns rel inside the contract directory, for example "fixtures/backend/backend.plugin.json".
// It panics when the variable is unset, because a test that silently read nothing would pass
// without checking the contract; run Go through scripts/desktop/desktop-go.sh instead.
func Path(rel string) string {
	dir := os.Getenv(EnvironmentVariable)
	if dir == "" {
		panic(EnvironmentVariable + " is not set; run Go through scripts/desktop/desktop-go.sh")
	}
	return filepath.Join(dir, filepath.FromSlash(rel))
}
