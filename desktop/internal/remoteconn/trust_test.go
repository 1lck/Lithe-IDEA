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

// Revoking needs no connection: it removes the named records, drops a target left empty and
// writes once; removals that name nothing write nothing, and a file changed since it was read
// is refused with ErrConflict.
func TestRemoteTrustRevokeRemovesRecordsWithoutAConnection(t *testing.T) {
	ctx := testContext(t)
	kernel := core.NewClient()
	root := filepath.Join(t.TempDir(), "preferences")
	file := filepath.Join(root, "toolchains", "remote-trust.json")
	if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
		t.Fatal(err)
	}
	devbox := `{"hops":[{"ssh":{"destination":"devbox","port":2222,"user":"dev"}}]}`
	lab := `{"hops":[{"ssh":{"destination":"lab"}},{"container":{"engine":"docker","program":"docker","container":"web"}}]}`
	wsl := `{"hops":[{"wsl":{"distribution":"Ubuntu","user":"dev"}}]}`
	seed := `{"version":1,"targets":[` +
		`{"target":` + devbox + `,"label":"Dev box","trustedWorkspaces":["/srv/app"],"distrustedWorkspaces":["/srv/tmp"]},` +
		`{"target":` + lab + `,"trustedLocations":["/work"]},` +
		`{"target":` + wsl + `,"trustedWorkspaces":["/home/dev/app"]}]}`
	if err := os.WriteFile(file, []byte(seed), 0o600); err != nil {
		t.Fatal(err)
	}
	trust, err := ReadTrust(ctx, kernel, root, "", "")
	if err != nil {
		t.Fatal(err)
	}
	targets := trust.State.Document.Targets
	if len(targets) != 3 {
		t.Fatalf("targets = %d", len(targets))
	}
	if place := targets[0].Place(); targets[0].Label != "Dev box" || place != "dev@devbox:2222" {
		t.Fatalf("first target: label set = %v, place matches = %v", targets[0].Label != "", place == "dev@devbox:2222")
	}
	if place := targets[1].Place(); place != "lab → docker:web" {
		t.Fatalf("second target place matches = %v", place == "lab → docker:web")
	}
	// A WSL distribution is named as the connection window names it.
	if place := targets[2].Place(); place != "wsl:dev@Ubuntu" {
		t.Fatalf("WSL target place matches = %v", place == "wsl:dev@Ubuntu")
	}

	absent := []core.RemoteWorkspaceTrustRevoke{{Target: targets[0].Target, List: core.RemoteTrustTrustedLocations, Path: "/srv"}}
	after, committed, err := trust.Revoke(ctx, kernel, absent)
	if err != nil || committed || len(after.Targets) != 3 {
		t.Fatalf("absent removal: committed = %v, targets = %d, err = %v", committed, len(after.Targets), err)
	}
	if text, _ := os.ReadFile(file); string(text) != seed {
		t.Fatal("a removal that names no record rewrote the file")
	}

	after, committed, err = trust.Revoke(ctx, kernel, []core.RemoteWorkspaceTrustRevoke{
		{Target: targets[0].Target, List: core.RemoteTrustDistrustedWorkspaces, Path: "/srv/tmp"},
		{Target: targets[1].Target, List: core.RemoteTrustTrustedLocations, Path: "/work"},
		{Target: targets[2].Target, List: core.RemoteTrustTrustedWorkspaces, Path: "/home/dev/app"},
	})
	if err != nil || !committed {
		t.Fatalf("removal: committed = %v, err = %v", committed, err)
	}
	if len(after.Targets) != 1 || len(after.Targets[0].TrustedWorkspaces) != 1 || len(after.Targets[0].DistrustedWorkspaces) != 0 {
		t.Fatalf("after removal: targets = %d", len(after.Targets))
	}
	reread, err := ReadTrust(ctx, kernel, root, "", "")
	if err != nil || len(reread.State.Document.Targets) != 1 || reread.State.Document.Targets[0].Label != "Dev box" {
		t.Fatalf("re-read: targets = %d, err = %v", len(reread.State.Document.Targets), err)
	}

	// trust still holds the bytes read before the removal: writing against them is refused.
	_, committed, err = trust.Revoke(ctx, kernel, []core.RemoteWorkspaceTrustRevoke{{Target: targets[0].Target, List: core.RemoteTrustTrustedWorkspaces, Path: "/srv/app"}})
	if !errors.Is(err, ErrConflict) || committed {
		t.Fatalf("stale removal: committed = %v, conflict = %v", committed, errors.Is(err, ErrConflict))
	}
}
