package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

// standInSSHConfig puts an ssh on PATH that prints `ssh -G` output: configured with the
// configuration files and baseline with `-F none`, for every destination.
func standInSSHConfig(t *testing.T, configured, baseline string) {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("the stand-in SSH client is a POSIX shell script")
	}
	dir := t.TempDir()
	script := "#!/bin/sh\ncase \" $* \" in\n*\" -F none \"*) printf '%s\\n' '" + baseline + "';;\n*) printf '%s\\n' '" + configured + "';;\nesac\n"
	if err := os.WriteFile(filepath.Join(dir, "ssh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// An import adds every entry in order, renames a clashing name instead of replacing the entry,
// and fills only the missing color or group; markConnected records the time and a query keeps
// only the matching entries in the sections.
func TestRemoteConnectionsImportMarkAndSearch(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	saved, err := client.EditRemoteConnections(ctx, nil, RemoteConnectionEdit{Save: &RemoteConnectionSave{
		Name: "Build box", Connection: SSHConnection{Host: "build.example"},
	}})
	if err != nil || saved.ID == "" {
		t.Fatalf("save = %+v, err = %v", saved, err)
	}
	imported, err := client.EditRemoteConnections(ctx, saved.Document, RemoteConnectionEdit{Import: &RemoteConnectionImport{
		Entries: []RemoteConnectionSave{
			{Name: "build box", Connection: SSHConnection{Host: "other.example"}, Group: "Lab"},
			{Name: "Scratch VM", Connection: SSHConnection{Host: "192.0.2.20", User: "dev"}, Color: RemoteConnectionGreen},
		},
		Fills: []RemoteConnectionFill{{ID: saved.ID, Color: RemoteConnectionBlue, Group: "Work"}},
	}})
	if err != nil || !imported.Changed || len(imported.IDs) != 2 {
		t.Fatalf("import = %+v, err = %v", imported, err)
	}
	names := map[string]SavedRemoteConnection{}
	for _, entry := range imported.Connections {
		names[entry.Name] = entry
	}
	if _, ok := names["build box (2)"]; !ok || names["Build box"].Color != RemoteConnectionBlue || names["Build box"].Group != "Work" {
		t.Fatalf("connections = %+v, want the clashing name renamed and the saved entry filled", imported.Connections)
	}
	if names["Build box"].LastConnectedAt != 0 {
		t.Fatalf("a fresh entry has a last connection: %+v", names["Build box"])
	}

	marked, err := client.EditRemoteConnections(ctx, imported.Document, RemoteConnectionEdit{MarkConnected: &RemoteConnectionID{ID: saved.ID}})
	if err != nil || !marked.Changed {
		t.Fatalf("mark = %+v, err = %v", marked, err)
	}
	for _, entry := range marked.Connections {
		if (entry.ID == saved.ID) != (entry.LastConnectedAt > 0) {
			t.Fatalf("entry %q last connected at %d", entry.Name, entry.LastConnectedAt)
		}
	}
	_, err = client.EditRemoteConnections(ctx, marked.Document, RemoteConnectionEdit{MarkConnected: &RemoteConnectionID{ID: "absent"}})
	if _, reason, ok := RemoteConnectionFieldError(err); !ok || reason != "unknown" {
		t.Fatalf("mark an absent entry: %v", err)
	}

	found, err := client.SearchRemoteConnections(ctx, marked.Document, "dev@192")
	if err != nil || len(found.Connections) != 3 || len(found.Sections) != 1 || len(found.Sections[0].IDs) != 1 || found.Sections[0].IDs[0] != imported.IDs[1] {
		t.Fatalf("search = %+v, err = %v, want only Scratch VM listed", found, err)
	}
}

// A quick-connect address splits into the form's fields, and a refused part names its field.
func TestRemoteParseAddressSplitsTheFields(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	address, err := client.RemoteParseAddress(ctx, "dev@build.example:2222")
	if err != nil || address != (RemoteAddress{Host: "build.example", User: "dev", Port: 2222}) {
		t.Fatalf("address = %+v, err = %v", address, err)
	}
	bare, err := client.RemoteParseAddress(ctx, "build-box")
	if err != nil || bare != (RemoteAddress{Host: "build-box"}) {
		t.Fatalf("alias = %+v, err = %v", bare, err)
	}
	_, err = client.RemoteParseAddress(ctx, "dev@build.example:99999")
	if field, _, ok := RemoteConnectionFieldError(err); !ok || field != "port" {
		t.Fatalf("port out of range: %v", err)
	}
}

// A Windows domain user, DOMAIN\name or name@domain, is saved as typed; one with only a domain is
// refused on the user field.
func TestRemoteConnectionsKeepWindowsDomainUsers(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	var document *string
	for _, user := range []string{`CONTOSO\admin`, "admin@contoso.example"} {
		saved, err := client.EditRemoteConnections(ctx, document, RemoteConnectionEdit{Save: &RemoteConnectionSave{
			Name: user, Connection: SSHConnection{Host: "192.0.2.10", User: user},
		}})
		if err != nil || saved.ID == "" {
			t.Fatalf("save domain user #%d: err = %v", len(user), err)
		}
		document = saved.Document
	}
	listed, err := client.SearchRemoteConnections(ctx, document, "")
	if err != nil || len(listed.Connections) != 2 {
		t.Fatalf("list: %d connections, err = %v", len(listed.Connections), err)
	}
	for _, entry := range listed.Connections {
		if entry.Connection.User != entry.Name {
			t.Fatalf("a domain user changed on save (%d bytes saved, %d typed)", len(entry.Connection.User), len(entry.Name))
		}
	}
	_, err = client.EditRemoteConnections(ctx, document, RemoteConnectionEdit{Save: &RemoteConnectionSave{
		Name: "Domain only", Connection: SSHConnection{Host: "192.0.2.10", User: `CONTOSO\`},
	}})
	if field, reason, ok := RemoteConnectionFieldError(err); !ok || field != "user" || reason != "invalid" {
		t.Fatalf("domain only: field %q, reason %q, want user and invalid", field, reason)
	}
}

// A port, host:port or URL typed into the Ports window becomes a forward target; a URL keeps its
// scheme and path and gives its default port, and a user name or password is refused by reason.
func TestRemoteParseForwardAddressReadsPortsAndURLs(t *testing.T) {
	client := NewClient()
	ctx := testContext(t)
	cases := map[string]RemoteForwardAddress{
		"3000":                          {TargetHost: "localhost", TargetPort: 3000},
		"10.0.0.5:9000":                 {TargetHost: "10.0.0.5", TargetPort: 9000},
		"[::1]:5432":                    {TargetHost: "::1", TargetPort: 5432},
		"HTTPS://Build.Example/app?x=1": {TargetHost: "build.example", TargetPort: 443, Scheme: "https", Path: "/app?x=1"},
		"http://localhost:3000/":        {TargetHost: "localhost", TargetPort: 3000, Scheme: "http"},
	}
	for text, want := range cases {
		if got, err := client.RemoteParseForwardAddress(ctx, text); err != nil || got != want {
			t.Errorf("address %q = %+v, err = %v, want %+v", text, got, err, want)
		}
	}
	for text, reason := range map[string]string{
		"https://dev:secret@build.example": "credentials",
		"postgres://build.example":         "port",
		"not a port":                       "malformed",
		"70000":                            "port",
	} {
		_, err := client.RemoteParseForwardAddress(ctx, text)
		if field, got, ok := RemoteConnectionFieldError(err); !ok || field != "text" || got != reason {
			t.Errorf("address #%d: field %q, reason %q, want text and %q", len(text), field, got, reason)
		}
	}
}

// The effective values name where each comes from: the connection, the SSH configuration or the
// default.
func TestRemoteEffectiveSettingsNameTheirSources(t *testing.T) {
	standInSSHConfig(t,
		"hostname 192.0.2.10\nuser dev\nport 2222\nidentityfile ~/.ssh/build_key\nconnecttimeout 15\nserveraliveinterval 0\nproxyjump jump-box",
		"hostname build-box\nuser localdev\nport 22\nidentityfile ~/.ssh/id_ed25519\nconnecttimeout 15\nserveraliveinterval 0\nproxyjump none",
	)
	settings, err := NewClient().RemoteEffectiveSettings(testContext(t), SSHConnection{Host: "build-box", User: "dev"}, nil)
	if err != nil {
		t.Fatalf("effective settings: %v", err)
	}
	if settings.HostName != (RemoteEffectiveText{Value: "192.0.2.10", Source: RemoteSettingFromSSHConfig}) ||
		settings.User != (RemoteEffectiveText{Value: "dev", Source: RemoteSettingFromConnection}) ||
		settings.Port != (RemoteEffectiveNumber{Value: 2222, Source: RemoteSettingFromSSHConfig}) ||
		settings.ConnectTimeoutSeconds.Source != RemoteSettingDefault {
		t.Fatalf("settings = %+v", settings)
	}
	if settings.ProxyJump == nil || settings.ProxyJump.Value != "jump-box" || len(settings.IdentityFiles.Value) != 1 {
		t.Fatalf("jump and keys = %+v, %+v", settings.ProxyJump, settings.IdentityFiles)
	}
}

// ~/.ssh/config lists each Host once with whether it can be imported; a wildcard is a pattern.
func TestRemoteSSHConfigHostsListTheAliases(t *testing.T) {
	standInSSHConfig(t,
		"hostname 192.0.2.10\nuser dev\nport 22\nconnecttimeout 15\nserveraliveinterval 0\nproxyjump none",
		"hostname 192.0.2.10\nuser dev\nport 22\nconnecttimeout 15\nserveraliveinterval 0\nproxyjump none",
	)
	home := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, ".ssh"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".ssh", "config"), []byte("Host build-box\n  HostName 192.0.2.10\n\nHost *.lab\n  User dev\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	hosts, err := NewClient().RemoteSSHConfigHosts(testContext(t), home, nil, nil)
	if err != nil || len(hosts.Files) != 1 || len(hosts.Hosts) != 2 {
		t.Fatalf("hosts = %+v, err = %v", hosts, err)
	}
	status := map[string]RemoteImportStatus{}
	for _, host := range hosts.Hosts {
		status[host.Alias] = host.Status
	}
	if status["build-box"] != RemoteImportable || status["*.lab"] != RemoteImportPattern {
		t.Fatalf("statuses = %+v", status)
	}
	if hosts.Hosts[0].Resolved == nil || hosts.Hosts[0].Resolved.HostName != "192.0.2.10" {
		t.Fatalf("resolved = %+v", hosts.Hosts[0].Resolved)
	}
}

// Without Motty's database the import is unavailable as a result, not an error.
func TestRemoteMottyHostsReportAMissingDatabase(t *testing.T) {
	hosts, err := NewClient().RemoteMottyHosts(testContext(t), t.TempDir(), nil)
	if err != nil || hosts.Unavailable != RemoteMottyMissing || hosts.Database == "" || len(hosts.Candidates) != 0 {
		t.Fatalf("hosts = %+v, err = %v", hosts, err)
	}
}

// A Remote question carries the kind Core classified and the host key it names.
func TestRemoteQuestionsCarryTheirKindAndHostKey(t *testing.T) {
	var asked GitAuthChallenge
	var stages []RemoteStage
	observe := gitAuthenticationObserver(func(challenge GitAuthChallenge) { asked = challenge }, nil,
		remoteStageObserver(WithRemoteStages(testContext(t), func(stage RemoteStage) { stages = append(stages, stage) })))
	for _, event := range []any{
		map[string]any{"type": "authentication", "requestId": "q1", "prompt": "Are you sure?", "kind": "hostKey", "keyType": "ED25519", "fingerprint": "SHA256:ZXhhbXBsZQ"},
		map[string]any{"type": "remoteStage", "stage": "uploading", "sentBytes": 262144, "totalBytes": 1048576},
	} {
		raw, err := json.Marshal(event)
		if err != nil {
			t.Fatal(err)
		}
		observe(raw)
	}
	if asked.Kind != RemoteQuestionHostKey || asked.KeyType != "ED25519" || asked.Fingerprint != "SHA256:ZXhhbXBsZQ" {
		t.Fatalf("question = %+v", asked)
	}
	if len(stages) != 1 || stages[0] != (RemoteStage{Stage: RemoteStageUploading, SentBytes: 262144, TotalBytes: 1048576}) {
		t.Fatalf("stages = %+v", stages)
	}
}
