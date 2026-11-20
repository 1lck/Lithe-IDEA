package workbench

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

const (
	commandDownloadPluginID = "dev.lithe.test.command-downloads"
	commandDownloadCommand  = "lithe-fixture-lldb"
)

// commandDownloadManifest declares a debug adapter that runs lithe-fixture-lldb from PATH and a
// download installer whose archive for every platform has digest and a mirror, with its
// commands in extension/adapter, a directory below the archive's top level.
func commandDownloadManifest(t *testing.T, digest string, timeoutSeconds int) string {
	t.Helper()
	var artifacts []map[string]any
	for _, system := range []string{"macos", "linux", "windows"} {
		for _, arch := range []string{"arm64", "x86_64"} {
			name := fmt.Sprintf("lithe-fixture-lldb-%s-%s.zip", system, arch)
			artifacts = append(artifacts, map[string]any{
				"os": system, "arch": arch,
				"url":     "https://downloads.example.org/lldb/1.2.3/" + name,
				"mirrors": []string{"https://mirror.example.net/lldb/1.2.3/" + name},
				"sha256":  digest, "archive": "zip",
			})
		}
	}
	encoded, err := json.Marshal(artifacts)
	if err != nil {
		t.Fatal(err)
	}
	return fmt.Sprintf(`{
  "schemaVersion": 0,
  "id": %q,
  "displayName": "Command Download Fixture",
  "version": "1.0.0",
  "pluginAPIVersion": 0,
  "requires": {"commandInstallers": 1, "debugAdapters": 0, "languages": 0},
  "vendor": {"id": "dev.lithe.test", "displayName": "Test", "signatureRequirement": "publisherPackage"},
  "permissions": ["commands.install", "debug.launch"],
  "activationEvents": ["onDebug:fixture"],
  "languages": [{"id": "fixture", "displayName": "Fixture", "fileExtensions": ["fixture"]}],
  "debugAdapters": [{
    "id": "fixture",
    "displayName": "Fixture LLDB",
    "adapterID": "fixture-lldb",
    "requests": ["launch"],
    "launch": {
      "process": {"launch": {"kind": "systemCommand", "commands": [%q]}, "arguments": ["--stdio"]},
      "transport": "stdio"
    }
  }],
  "commandInstallers": [{
    "id": "fixture-lldb",
    "commands": [%q],
    "download": {"version": "1.2.3", "artifacts": %s},
    "mayUseNetwork": true,
    "timeoutSeconds": %d,
    "targets": {"managed": {"commandDirectory": "extension/adapter"}}
  }]
}`, commandDownloadPluginID, commandDownloadCommand, commandDownloadCommand, encoded, timeoutSeconds)
}

// fixtureZip is a zip archive of files, each name mapped to its mode. Nothing in it runs.
func fixtureZip(t *testing.T, files map[string]os.FileMode) []byte {
	t.Helper()
	names := make([]string, 0, len(files))
	for name := range files {
		names = append(names, name)
	}
	slices.Sort(names)
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	for _, name := range names {
		header := &zip.FileHeader{Name: name, Method: zip.Deflate}
		header.SetMode(files[name])
		writer, err := archive.CreateHeader(header)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := writer.Write([]byte("fixture " + name + "\n")); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

// adapterArchive is an archive with the fixture command in extension/adapter next to a data file.
func adapterArchive(t *testing.T) []byte {
	t.Helper()
	name := commandDownloadCommand
	if runtime.GOOS == "windows" {
		name += ".exe"
	}
	return fixtureZip(t, map[string]os.FileMode{
		"extension/package.json":    0o644,
		"extension/adapter/" + name: 0o755,
	})
}

func sha256Hex(data []byte) string {
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}

// archiveServer answers the fixture's archive hosts in memory and counts the requests.
type archiveServer struct {
	mu       sync.Mutex
	requests []string
	// serve answers one request; nil serves body.
	serve func(*http.Request) (*http.Response, error)
	body  []byte
}

func (s *archiveServer) RoundTrip(request *http.Request) (*http.Response, error) {
	s.mu.Lock()
	s.requests = append(s.requests, request.Method+" "+request.URL.String())
	serve := s.serve
	s.mu.Unlock()
	if serve != nil {
		return serve(request)
	}
	return archiveResponse(request, http.StatusOK, s.body), nil
}

func (s *archiveServer) seen() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Clone(s.requests)
}

func archiveResponse(request *http.Request, status int, body []byte) *http.Response {
	if request.Method == http.MethodHead {
		return &http.Response{StatusCode: status, Header: http.Header{}, Body: http.NoBody, ContentLength: int64(len(body)), Request: request}
	}
	return &http.Response{
		StatusCode:    status,
		Header:        http.Header{"Content-Type": {"application/zip"}},
		Body:          io.NopCloser(bytes.NewReader(body)),
		ContentLength: int64(len(body)),
		Request:       request,
	}
}

// hangUntilCancelled answers nothing until the request's context ends.
func hangUntilCancelled(request *http.Request) (*http.Response, error) {
	<-request.Context().Done()
	return nil, request.Context().Err()
}

// commandDownloadHarness installs the download fixture plugin pinning digest, with its archive
// hosts answered by server. It returns the harness and the installer's managed directory.
func commandDownloadHarness(t *testing.T, digest string, timeoutSeconds int, server *archiveServer) (*harness, string) {
	t.Helper()
	h := debugPluginHarness(t, commandDownloadPluginID, commandDownloadManifest(t, digest, timeoutSeconds), false)
	h.app.plugins.RuntimeDownloader = marketplace.NewArchiveDownloader(&http.Client{Transport: server})
	root, err := h.app.plugins.Commands.InstallDirectory(commandDownloadPluginID, "fixture-lldb")
	if err != nil {
		t.Fatal(err)
	}
	return h, root
}

// hostArchiveName is the file name of the fixture archive for this machine's platform.
func hostArchiveName() string {
	platform := pluginservice.ArchivePlatform()
	return fmt.Sprintf("lithe-fixture-lldb-%s-%s.zip", platform.OS, platform.Arch)
}

func TestCommandDownloadOfferShowsTheArchiveWithoutFetchingIt(t *testing.T) {
	archive := adapterArchive(t)
	server := &archiveServer{body: archive}
	h, root := commandDownloadHarness(t, sha256Hex(archive), 900, server)
	installs := settingsCommandInstalls{app: h.app}
	ctx := commandInstallContext(t)

	missing, err := installs.Missing(ctx, commandDownloadPluginID)
	if err != nil {
		t.Fatal(err)
	}
	// A download runs no tool, so the card names none.
	expectedMissing := []settingswindow.MissingCommand{{Kind: settingswindow.CapabilityDebugger, ID: "fixture", Commands: []string{commandDownloadCommand}, Installer: "fixture-lldb"}}
	if !reflect.DeepEqual(missing, expectedMissing) {
		t.Fatalf("missing = %+v\nwant %+v", missing, expectedMissing)
	}

	offer, err := installs.Offer(ctx, commandDownloadPluginID, "fixture-lldb")
	if err != nil {
		t.Fatal(err)
	}
	expected := settingswindow.CommandInstallOffer{
		Installer:     "fixture-lldb",
		Commands:      []string{commandDownloadCommand},
		MayUseNetwork: true,
		Timeout:       900 * time.Second,
		Download: &settingswindow.CommandInstallDownload{
			Version: "1.2.3",
			URL:     "https://downloads.example.org/lldb/1.2.3/" + hostArchiveName(),
			Mirrors: []string{"https://mirror.example.net/lldb/1.2.3/" + hostArchiveName()},
			SHA256:  sha256Hex(archive),
		},
		Targets: []settingswindow.CommandInstallTarget{{Target: core.CommandInstallManaged, Directory: root}},
	}
	if !reflect.DeepEqual(offer, expected) {
		t.Fatalf("offer = %+v\nwant %+v", offer, expected)
	}
	// The offer is read before the user agrees: nothing is fetched and nothing is created.
	if requests := server.seen(); len(requests) != 0 {
		t.Fatalf("the offer sent %q", requests)
	}
	if _, err := os.Stat(root); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("the offer created the install directory: %v", err)
	}
}

// downloadProgress collects an installation's progress.
type downloadProgress struct {
	mu     sync.Mutex
	phases []string
}

func (p *downloadProgress) add(progress pluginruntime.Progress) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.phases = append(p.phases, progress.Phase)
}

func (p *downloadProgress) all() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return slices.Clone(p.phases)
}

func TestCommandDownloadExtractsAndRecordsWhereLaterLaunchesFindTheCommand(t *testing.T) {
	archive := adapterArchive(t)
	server := &archiveServer{body: archive}
	h, root := commandDownloadHarness(t, sha256Hex(archive), 900, server)
	installs := settingsCommandInstalls{app: h.app}
	ctx := commandInstallContext(t)
	// What the archive of a version pinned before an update left behind.
	stale := filepath.Join(root, "0123456789abcdef")
	if err := os.MkdirAll(filepath.Join(stale, "install-old", "extension", "adapter"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(stale, "archive"), []byte("older archive"), 0o600); err != nil {
		t.Fatal(err)
	}

	var progress downloadProgress
	directory, err := installs.Install(ctx, commandDownloadPluginID, "fixture-lldb", core.CommandInstallManaged, func(line string) {
		t.Errorf("a download printed %q", line)
	}, progress.add)
	if err != nil {
		t.Fatal(err)
	}
	relative, err := filepath.Rel(root, directory)
	if err != nil || !filepath.IsLocal(relative) || filepath.Base(directory) != "adapter" || filepath.Base(filepath.Dir(directory)) != "extension" {
		t.Fatalf("installed into %q, want extension/adapter below %q", directory, root)
	}
	if !slices.Contains(progress.all(), "downloading") {
		t.Fatalf("progress = %q, want the transfer", progress.all())
	}
	// Only the extraction that was just recorded is kept.
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || !strings.HasPrefix(relative, entries[0].Name()+string(filepath.Separator)) {
		t.Fatalf("the install directory holds %v, want only the extraction of %s", entries, relative)
	}
	installations := h.app.plugins.Commands.Installations(commandDownloadPluginID)
	if !reflect.DeepEqual(installations, []pluginhost.CommandInstallation{{Installer: "fixture-lldb", Target: core.CommandInstallManaged, Directory: directory}}) {
		t.Fatalf("recorded %+v", installations)
	}
	command, err := h.app.plugins.Backend.ResolveCommand(commandDownloadPluginID, []string{commandDownloadCommand})
	if err != nil || filepath.Dir(command) != directory {
		t.Fatalf("debug adapter command = %q, %v", command, err)
	}
	missing, err := installs.Missing(ctx, commandDownloadPluginID)
	if err != nil {
		t.Fatal(err)
	}
	if len(missing) != 0 {
		t.Fatalf("still missing after the install: %+v", missing)
	}
	gets := func() int {
		count := 0
		for _, request := range server.seen() {
			if strings.HasPrefix(request, http.MethodGet+" ") {
				count++
			}
		}
		return count
	}
	if n := gets(); n != 1 {
		t.Fatalf("the archive was fetched %d times", n)
	}

	// The extraction in place still holds the command, so installing again fetches nothing.
	sent := len(server.seen())
	again, err := installs.Install(ctx, commandDownloadPluginID, "fixture-lldb", core.CommandInstallManaged, func(string) {}, nil)
	if err != nil || again != directory {
		t.Fatalf("second Install = %q, %v; want %q", again, err, directory)
	}
	if requests := server.seen(); len(requests) != sent {
		t.Fatalf("the second install sent %q", requests[sent:])
	}
}

func TestCommandDownloadReportsWhyTheCommandsDidNotLand(t *testing.T) {
	adapter := adapterArchive(t)
	withoutCommand := fixtureZip(t, map[string]os.FileMode{"extension/adapter/other": 0o755})
	escaping := fixtureZip(t, map[string]os.FileMode{"../escaped": 0o644})
	for _, test := range []struct {
		name   string
		digest string
		server *archiveServer
		check  func(t *testing.T, failure *pluginhost.CommandInstallError)
	}{
		{"digest differs", sha256Hex(adapter), &archiveServer{body: append(slices.Clone(adapter), 0)}, func(t *testing.T, failure *pluginhost.CommandInstallError) {
			if failure.Code != pluginhost.CommandInstallChecksumMismatchCode || !errors.Is(failure, marketplace.ErrArchiveChecksum) {
				t.Fatalf("failure = %+v", failure)
			}
		}},
		{"not served", sha256Hex(adapter), &archiveServer{serve: func(request *http.Request) (*http.Response, error) {
			return archiveResponse(request, http.StatusNotFound, nil), nil
		}}, func(t *testing.T, failure *pluginhost.CommandInstallError) {
			if failure.Code != pluginhost.CommandInstallDownloadFailedCode || !errors.Is(failure, pluginruntime.ErrDownload) {
				t.Fatalf("failure = %+v", failure)
			}
		}},
		{"command not in the archive", sha256Hex(withoutCommand), &archiveServer{body: withoutCommand}, func(t *testing.T, failure *pluginhost.CommandInstallError) {
			// The extraction is discarded, so the failure names the place in the archive.
			location := path.Join(hostArchiveName(), "extension/adapter")
			if failure.Code != pluginhost.CommandInstallCommandsMissingCode || failure.Directory != location ||
				!reflect.DeepEqual(failure.Commands, []string{commandDownloadCommand}) {
				t.Fatalf("failure = %+v, want %s missing from %s", failure, commandDownloadCommand, location)
			}
		}},
		{"entry outside the archive", sha256Hex(escaping), &archiveServer{body: escaping}, func(t *testing.T, failure *pluginhost.CommandInstallError) {
			if failure.Code != pluginhost.CommandInstallArchiveInvalidCode || !errors.Is(failure, pluginruntime.ErrArchive) {
				t.Fatalf("failure = %+v", failure)
			}
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			h, root := commandDownloadHarness(t, test.digest, 900, test.server)
			logger := &treeRecordingLog{}
			h.app.logSink = logger
			installs := settingsCommandInstalls{app: h.app}
			installed, err := installs.Install(commandInstallContext(t), commandDownloadPluginID, "fixture-lldb", core.CommandInstallManaged, func(string) {}, nil)
			var failure *pluginhost.CommandInstallError
			if !errors.As(err, &failure) {
				t.Fatalf("Install = %q, %v; want a CommandInstallError", installed, err)
			}
			test.check(t, failure)
			if installations := h.app.plugins.Commands.Installations(commandDownloadPluginID); len(installations) != 0 {
				t.Fatalf("a failed installation was recorded: %+v", installations)
			}
			// Nothing the archive names lands anywhere in the plugin's command directories.
			if err := filepath.WalkDir(filepath.Dir(root), func(name string, entry fs.DirEntry, err error) error {
				if err != nil {
					return err
				}
				if entry.Name() == "escaped" {
					t.Errorf("the archive wrote %s", name)
				}
				return nil
			}); err != nil && !errors.Is(err, fs.ErrNotExist) {
				t.Fatal(err)
			}
			// The click and the failure the dialog shows are each logged once.
			if n := countPerformed(logger, "plugin.commandInstaller.install"); n != 1 {
				t.Fatalf("the install action was logged %d times", n)
			}
			if failed := loggedEvents(logger, operationFailedEvent); len(failed) != 1 || failed[0].Fields["operation"] != "plugin_command_install" {
				t.Fatalf("operation failures = %+v, want the one install failure", failed)
			}
		})
	}
}

func TestCommandDownloadStopsWhenCancelled(t *testing.T) {
	ctx, cancel := context.WithCancel(commandInstallContext(t))
	defer cancel()
	// The archive hosts answer nothing; cancelling once the first request arrives stops the
	// installation mid-transfer.
	server := &archiveServer{serve: func(request *http.Request) (*http.Response, error) {
		cancel()
		return hangUntilCancelled(request)
	}}
	archive := adapterArchive(t)
	h, _ := commandDownloadHarness(t, sha256Hex(archive), 900, server)
	logger := &treeRecordingLog{}
	h.app.logSink = logger
	installs := settingsCommandInstalls{app: h.app}
	if _, err := installs.Install(ctx, commandDownloadPluginID, "fixture-lldb", core.CommandInstallManaged, func(string) {}, nil); !errors.Is(err, context.Canceled) {
		t.Fatalf("Install = %v, want the cancel", err)
	}
	if installations := h.app.plugins.Commands.Installations(commandDownloadPluginID); len(installations) != 0 {
		t.Fatalf("a cancelled installation was recorded: %+v", installations)
	}
	// A cancel is not a failure.
	if failed := loggedEvents(logger, operationFailedEvent); len(failed) != 0 {
		t.Fatalf("the cancel was logged as a failure: %+v", failed)
	}
}

func TestCommandDownloadEndsAtItsTimeout(t *testing.T) {
	archive := adapterArchive(t)
	h, _ := commandDownloadHarness(t, sha256Hex(archive), 1, &archiveServer{serve: hangUntilCancelled})
	installs := settingsCommandInstalls{app: h.app}
	_, err := installs.Install(commandInstallContext(t), commandDownloadPluginID, "fixture-lldb", core.CommandInstallManaged, func(string) {}, nil)
	var failure *pluginhost.CommandInstallError
	if !errors.As(err, &failure) || failure.Code != pluginhost.CommandInstallTimedOutCode || failure.Timeout != time.Second {
		t.Fatalf("Install = %v, want the one-second timeout", err)
	}
	if installations := h.app.plugins.Commands.Installations(commandDownloadPluginID); len(installations) != 0 {
		t.Fatalf("a timed-out installation was recorded: %+v", installations)
	}
}
