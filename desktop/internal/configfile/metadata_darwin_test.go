package configfile

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Native integration: chmod and ls expose the operating system's extended ACL
// without another ACL parser in the product or in this assertion.
func TestNativeConfigPublicationPreservesDarwinACL(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "settings.json")
	if err := os.WriteFile(path, []byte("original"), 0o640); err != nil {
		t.Fatal(err)
	}
	command := func(program string, args ...string) string {
		t.Helper()
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, program, args...)
		cmd.WaitDelay = time.Second
		output, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("native ACL command: %v, %s", err, output)
		}
		return string(output)
	}
	command("/bin/chmod", "+a", "everyone allow read,readattr,readextattr,readsecurity", path)
	acl := func() string {
		_, entries, ok := strings.Cut(command("/bin/ls", "-le", path), "\n")
		if !ok || !strings.Contains(entries, "everyone") {
			t.Fatal("native ACL fixture was not installed")
		}
		return entries
	}
	before := acl()
	snapshot, err := Capture(context.Background(), root, "settings.json", 4096)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := snapshot.Replace(context.Background(), []byte("changed"), nil); err != nil {
		t.Fatal(err)
	}
	if after := acl(); after != before {
		t.Fatalf("ACL changed:\nbefore: %safter: %s", before, after)
	}
	assertNoTemporaryFiles(t, root)
}
