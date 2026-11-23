// Package remoteserver carries the Linux builds of the remote workspace server inside the client
// binary and gives remote.connect the files and SHA-256 values to send to a host (#2231).
//
// scripts/desktop/build-remote-server.sh builds the server for each Linux target from the Core
// revision the client links, and writes a manifest with every build's size and SHA-256.
// scripts/desktop/package-desktop.sh embeds the builds and that manifest under the build tag
// lithe_bundled_remote_server, so both are part of the signed client executable. remote.connect
// takes the manifest's SHA-256 as the value the build must have, never one computed from the file
// it is about to send (S17), so a file replaced on disk is refused before anything reaches a host.
//
// Core reads a build from a path, so the client writes each embedded build once below a directory
// of the user (DefaultDir) and rewrites it only when its bytes differ. The installed app bundle and
// installation directory are never written; the copies are regenerated from the executable at any
// time, which is why they live in the user's cache directory.
package remoteserver

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"github.com/1lck/Lithe-IDEA/desktop/internal/atomicfile"
)

// ManifestFile is the manifest's file name, in the stage of build-remote-server.sh and in this
// package's embedded files.
const ManifestFile = "remote-server-manifest.json"

// BinaryName is the server executable's file name inside each target's directory.
const BinaryName = "lithe-remote-server"

// StageEnv names the stage of build-remote-server.sh that a development run without embedded
// builds uses; scripts/desktop/desktop-go.sh sets it when the stage has a manifest. A packaged
// client ignores it.
const StageEnv = "LITHE_REMOTE_SERVER_STAGE"

// ErrNotBundled means this client has neither embedded builds nor a stage: a development build
// without the packaging tag, and without a staged server, cannot connect to a host.
var ErrNotBundled = errors.New("remoteserver: this build carries no remote server builds")

// ErrMismatch means a build's bytes are not those its manifest describes. For the embedded builds
// that is a packaging defect; for a stage, a build that changed after its manifest was written.
var ErrMismatch = errors.New("remoteserver: a server build does not match its manifest")

// Build is one server build as remote.connect takes it.
type Build struct {
	// Target is the Rust target, such as x86_64-unknown-linux-musl.
	Target string `json:"target"`
	// Path is the absolute path of the file Core reads and sends.
	Path string `json:"path"`
	// SHA256 is the manifest's SHA-256 of the build, 64 lowercase hexadecimal digits.
	SHA256 string `json:"sha256"`
}

// Bundle is what remote.connect needs from the client: the server version and one build per
// target, in the manifest's order.
type Bundle struct {
	Version string
	Builds  []Build
}

// manifest is the part of build-remote-server.sh's manifest this package reads.
type manifest struct {
	SchemaVersion int        `json:"schemaVersion"`
	ServerVersion string     `json:"serverVersion"`
	Artifacts     []artifact `json:"artifacts"`
}

type artifact struct {
	Target string `json:"target"`
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

// source is the embedded manifest and a reader of the embedded build of a target. A nil source
// means this build embeds none.
type source struct {
	manifest []byte
	build    func(target string) ([]byte, error)
}

// embedded is the client's embedded builds. A test replaces it to install builds without
// packaging; production always reads the embedded files.
var embedded = bundled

// installMu serializes installation within the process, so two windows connecting at once never
// replace a file the other is writing.
var installMu sync.Mutex

// DefaultDir is the directory the client installs the embedded builds below: Lithe/remote-server
// in the user's cache directory.
func DefaultDir() (string, error) {
	base, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("remoteserver: locate the cache directory: %w", err)
	}
	return filepath.Join(base, "Lithe", "remote-server"), nil
}

// Resolve returns the builds a connection sends. A packaged client installs its embedded builds
// below dir (Install); a development build without them uses the stage StageEnv names (Staged).
// Without either it returns ErrNotBundled.
func Resolve(dir string) (Bundle, error) {
	if embedded() != nil {
		return Install(dir)
	}
	if stage := os.Getenv(StageEnv); stage != "" {
		return Staged(stage)
	}
	return Bundle{}, ErrNotBundled
}

// Install writes every embedded build to dir/<target>/lithe-remote-server and returns them. It
// first checks each build against the embedded manifest and installs nothing when one differs
// (ErrMismatch). A file that already has a build's bytes is kept as it is; any other file there,
// including a link, is replaced atomically, so a partial build is never left where Core reads it.
// The files are private to the user and not executable: Core reads them, and only a host runs
// them.
func Install(dir string) (Bundle, error) {
	src := embedded()
	if src == nil {
		return Bundle{}, ErrNotBundled
	}
	parsed, err := parseManifest(src.manifest)
	if err != nil {
		return Bundle{}, err
	}
	builds := make([][]byte, len(parsed.Artifacts))
	for i, entry := range parsed.Artifacts {
		data, err := src.build(entry.Target)
		if err != nil {
			return Bundle{}, fmt.Errorf("remoteserver: read the embedded %s build: %w", entry.Target, err)
		}
		if err := entry.check(data); err != nil {
			return Bundle{}, err
		}
		builds[i] = data
	}
	root, err := filepath.Abs(dir)
	if err != nil {
		return Bundle{}, fmt.Errorf("remoteserver: resolve the install directory: %w", err)
	}
	installMu.Lock()
	defer installMu.Unlock()
	bundle := Bundle{Version: parsed.ServerVersion, Builds: make([]Build, len(builds))}
	for i, entry := range parsed.Artifacts {
		target := filepath.Join(root, entry.Target, BinaryName)
		if err := installFile(target, builds[i]); err != nil {
			return Bundle{}, fmt.Errorf("remoteserver: install the %s build: %w", entry.Target, err)
		}
		bundle.Builds[i] = Build{Target: entry.Target, Path: target, SHA256: entry.SHA256}
	}
	return bundle, nil
}

// Staged returns the builds build-remote-server.sh staged in stage, read where they are, after
// checking each against the stage's manifest (ErrMismatch when one differs). It is for
// development runs: a stage is not signed with the client, so only Install provides the S17
// guarantee.
func Staged(stage string) (Bundle, error) {
	root, err := filepath.Abs(stage)
	if err != nil {
		return Bundle{}, fmt.Errorf("remoteserver: resolve the stage: %w", err)
	}
	data, err := os.ReadFile(filepath.Join(root, ManifestFile))
	if err != nil {
		return Bundle{}, fmt.Errorf("remoteserver: read the staged manifest: %w", err)
	}
	parsed, err := parseManifest(data)
	if err != nil {
		return Bundle{}, err
	}
	bundle := Bundle{Version: parsed.ServerVersion, Builds: make([]Build, len(parsed.Artifacts))}
	for i, entry := range parsed.Artifacts {
		path := filepath.Join(root, entry.Target, BinaryName)
		build, err := os.ReadFile(path)
		if err != nil {
			return Bundle{}, fmt.Errorf("remoteserver: read the staged %s build: %w", entry.Target, err)
		}
		if err := entry.check(build); err != nil {
			return Bundle{}, err
		}
		bundle.Builds[i] = Build{Target: entry.Target, Path: path, SHA256: entry.SHA256}
	}
	return bundle, nil
}

// parseManifest reads a manifest of schema 1 and checks what this package relies on: a server
// version, at least one build, each target once and stored at <target>/lithe-remote-server, a
// positive size and a SHA-256 of 64 lowercase hexadecimal digits. The set of targets and the
// version's syntax are Core's to check: remote.connect refuses a target or version it does not
// know.
func parseManifest(data []byte) (manifest, error) {
	var parsed manifest
	decoder := json.NewDecoder(bytes.NewReader(data))
	if err := decoder.Decode(&parsed); err != nil {
		return manifest{}, fmt.Errorf("remoteserver: decode the manifest: %w", err)
	}
	invalid := func(reason string) (manifest, error) {
		return manifest{}, fmt.Errorf("remoteserver: invalid manifest: %s", reason)
	}
	if parsed.SchemaVersion != 1 {
		return invalid(fmt.Sprintf("schema version %d, want 1", parsed.SchemaVersion))
	}
	if parsed.ServerVersion == "" {
		return invalid("no server version")
	}
	if len(parsed.Artifacts) == 0 {
		return invalid("no builds")
	}
	seen := make(map[string]bool, len(parsed.Artifacts))
	for _, entry := range parsed.Artifacts {
		if !validTarget(entry.Target) || seen[entry.Target] {
			return invalid(fmt.Sprintf("target %q is malformed or repeated", entry.Target))
		}
		seen[entry.Target] = true
		if entry.Path != entry.Target+"/"+BinaryName {
			return invalid(fmt.Sprintf("the %s build is not at %s/%s", entry.Target, entry.Target, BinaryName))
		}
		if entry.Size <= 0 || !validSHA256(entry.SHA256) {
			return invalid(fmt.Sprintf("the %s build has no size or no lowercase SHA-256", entry.Target))
		}
	}
	return parsed, nil
}

// check reports ErrMismatch unless data has the entry's size and SHA-256.
func (entry artifact) check(data []byte) error {
	sum := sha256.Sum256(data)
	if int64(len(data)) != entry.Size || hex.EncodeToString(sum[:]) != entry.SHA256 {
		return fmt.Errorf("%w: %s", ErrMismatch, entry.Target)
	}
	return nil
}

// validTarget accepts a Rust target name: lowercase letters, digits, '_' and '-', so it is always
// one path element.
func validTarget(target string) bool {
	if target == "" {
		return false
	}
	for _, r := range target {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '_' || r == '-') {
			return false
		}
	}
	return true
}

func validSHA256(value string) bool {
	if len(value) != sha256.Size*2 {
		return false
	}
	for _, r := range value {
		if !(r >= '0' && r <= '9' || r >= 'a' && r <= 'f') {
			return false
		}
	}
	return true
}

// rename is os.Rename; tests replace it to emulate a competing installer.
var rename = os.Rename

// installFile reuses an existing immutable resource or replaces it atomically.
func installFile(target string, data []byte) error {
	return atomicfile.InstallWithRename(target, data, 0o600, rename)
}
