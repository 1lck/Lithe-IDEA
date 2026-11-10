package pluginservice

import (
	"context"
	"os"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
)

// TestJavaSupportManifestOnlyLacksOtherLanesCapabilities validates the real Java
// Support manifest against the capabilities this client declares and lists what
// is still missing. The manifest lives in the plugin's own repository, so the
// test runs when LITHE_JAVA_PLUGIN_MANIFEST names it and is skipped otherwise.
//
// The backend, plugin-function and language-server capabilities of this lane are
// declared; what remains belongs to the debug adapter, output link, project
// generator and settings surfaces, which other work wires.
func TestJavaSupportManifestOnlyLacksOtherLanesCapabilities(t *testing.T) {
	path := os.Getenv("LITHE_JAVA_PLUGIN_MANIFEST")
	if path == "" {
		t.Skip("LITHE_JAVA_PLUGIN_MANIFEST is not set")
	}
	manifest, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	unsupported := regexp.MustCompile(`capability (\w+) (\d+)`)
	capabilities := pluginhost.Declared()
	var missing []string
	for range 16 {
		_, err := core.NewClient().ValidatePluginManifest(ctx, manifest, capabilities.Clone())
		if err == nil {
			sort.Strings(missing)
			want := []string(nil)
			if !reflect.DeepEqual(missing, want) {
				t.Fatalf("missing capabilities = %v, want %v", missing, want)
			}
			return
		}
		match := unsupported.FindStringSubmatch(err.Error())
		if match == nil {
			t.Fatalf("the Java Support manifest is refused for another reason: %v", err)
		}
		version, _ := strconv.Atoi(match[2])
		missing = append(missing, match[1]+" "+match[2])
		capabilities = capabilities.With(match[1], version)
	}
	t.Fatal("too many missing capabilities")
}
