package localshell

import (
	"os"
	"testing"

	"github.com/vivaui/viva/leaks"
)

// The tests must close every shell and worker they start.
func TestMain(m *testing.M) { os.Exit(leaks.Main(m)) }
