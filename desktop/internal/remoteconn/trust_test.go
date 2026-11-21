package remoteconn

import (
	"errors"
	"os"
	"path/filepath"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// An import names the entries it added, in order, and Document hands the stored text to Core.
func TestApplyingAnImportNamesTheAddedEntries(t *testing.T) {
	ctx := testContext(t)
	kernel := core.NewClient()
	source, err := Read(ctx, kernel, t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if document, err := source.Document(); err != nil || document != nil {
		t.Fatalf("absent document = %v, err = %v", document, err)
	}
	after, publication, committed, err := source.Apply(ctx, kernel, core.RemoteConnectionEdit{Import: &core.RemoteConnectionImport{
		Entries: []core.RemoteConnectionSave{
			{Name: "Build box", Connection: core.SSHConnection{Host: "build.example"}},
			{Name: "Lab ARM", Connection: core.SSHConnection{Host: "192.0.2.30"}, Group: "Lab"},
		},
	}})
	if err != nil || !committed || len(publication.IDs) != 2 || len(after.Connections) != 2 {
		t.Fatalf("import = %+v, committed = %v, err = %v", publication, committed, err)
	}
	if after.Connections[0].ID != publication.IDs[0] || after.Connections[1].ID != publication.IDs[1] {
		t.Fatalf("ids = %v, connections = %+v", publication.IDs, after.Connections)
	}
	document, err := after.Document()
	if err != nil || document == nil {
		t.Fatalf("document = %v, err = %v", document, err)
	}
}

// Reading remote trust creates nothing and names the preference file Core keeps it in; a
// decision over a session Core does not know writes nothing.
func TestRemoteTrustReadsWithoutWritingAndRefusesAClosedSession(t *testing.T) {
	ctx := testContext(t)
	kernel := core.NewClient()
	root := filepath.Join(t.TempDir(), "preferences")
	trust, err := ReadTrust(ctx, kernel, root, "", "")
	if err != nil || trust.State.Storage.RelativePath != "toolchains/remote-trust.json" || trust.State.WorkspaceTrust != nil {
		t.Fatalf("trust = %+v, err = %v", trust.State, err)
	}
	committed, err := trust.Decide(ctx, kernel, core.RemoteWorkspaceTrustDecision{SessionID: "absent", Workspace: "/home/dev/app", Trusted: true})
	if err == nil || committed {
		t.Fatalf("decision over an absent session: committed = %v, err = %v", committed, err)
	}
	if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("a refused decision created %s: %v", root, err)
	}
}
