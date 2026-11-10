// Package mcpconfig is the platform side of the MCP server library: it finds the native
// configuration files of Codex and Claude Code, reads them, and publishes the changes Core
// planned. Core owns every rule (parsing, merging, ownership, validation, the batch plan);
// this package owns paths, bounded reads, backups, atomic replacement, rollback and the
// ownership ledger.
//
// The files belong to the tools, not to Lithe. A server Lithe did not write is changed only
// when the user explicitly edits it, with the hash of the entry they saw as the
// precondition, so an external edit between reading and writing is refused, never
// overwritten. Nothing here writes into the application bundle or the install directory:
// backups and the ledger live in the data directory the caller supplies.
package mcpconfig

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// MaximumFileBytes is Core's accepted configuration size.
const MaximumFileBytes = 1 << 20

// Kernel is what the service asks Core. *core.Client implements it.
type Kernel interface {
	McpLibrarySnapshot(ctx context.Context, files []core.McpLibraryFile) (core.McpLibrarySnapshot, error)
	McpBatchPlan(ctx context.Context, files []core.McpLibraryFile, intent core.McpBatchIntent) (core.McpBatchPlan, error)
	McpToolPolicy(ctx context.Context, request core.McpToolPolicyRequest) (core.McpToolPolicy, error)
	McpProbe(ctx context.Context, request core.McpProbeRequest) ([]core.McpTool, error)
}

// Environment locates the user's files. Getenv may be nil.
type Environment struct {
	Home   string
	Getenv func(string) string
}

func (e Environment) env(name string) string {
	if e.Getenv == nil {
		return ""
	}
	return e.Getenv(name)
}

// CodexConfigPath is $CODEX_HOME/config.toml, else ~/.codex/config.toml.
func (e Environment) CodexConfigPath() string {
	if home := e.env("CODEX_HOME"); home != "" {
		return filepath.Join(home, "config.toml")
	}
	return filepath.Join(e.Home, ".codex", "config.toml")
}

// ClaudeConfigPath is $CLAUDE_CONFIG_DIR/.claude.json, else ~/.claude.json.
func (e Environment) ClaudeConfigPath() string {
	if dir := e.env("CLAUDE_CONFIG_DIR"); dir != "" {
		return filepath.Join(dir, ".claude.json")
	}
	return filepath.Join(e.Home, ".claude.json")
}

// ClaudeSettingsPath is the user settings file that holds Claude's tool permissions.
func (e Environment) ClaudeSettingsPath() string {
	if dir := e.env("CLAUDE_CONFIG_DIR"); dir != "" {
		return filepath.Join(dir, "settings.json")
	}
	return filepath.Join(e.Home, ".claude", "settings.json")
}

// Locations lists the files of the library in the order Core keeps for ties: the global
// files of Codex and Claude, then, with a project open, Claude's and Codex's project files.
// Content and ledger are left empty.
func Locations(env Environment, project string) []core.McpLibraryFile {
	files := []core.McpLibraryFile{
		{ID: "codex|global|", Source: "codex", Scope: "global", Path: env.CodexConfigPath()},
		{ID: "claude|global|", Source: "claude", Scope: "global", Path: env.ClaudeConfigPath()},
	}
	if project != "" {
		project = filepath.Clean(project)
		files = append(files,
			core.McpLibraryFile{ID: "claude|project|" + project, Source: "claude", Scope: "project", ProjectPath: project, Path: env.ClaudeConfigPath()},
			core.McpLibraryFile{ID: "codex|project|" + project, Source: "codex", Scope: "project", ProjectPath: project, Path: filepath.Join(project, ".codex", "config.toml")},
		)
	}
	return files
}

// ReadFailure names a file that could not be read; the content is never echoed.
type ReadFailure struct {
	File string
	Path string
	Err  error
}

// Library is one read of every file, with Core's merged view of it. The snapshots keep the
// bytes a later write is checked against.
type Library struct {
	Project  string
	Files    []core.McpLibraryFile
	Snapshot core.McpLibrarySnapshot
	// ReadFailures are files that could not be read. A write is refused while any exist.
	ReadFailures []ReadFailure
	captured     map[string]configfile.Snapshot
}

// Service reads and writes the library. It is safe for concurrent use; writes are
// serialized.
type Service struct {
	kernel Kernel
	env    Environment
	// dataDir holds the ledger and the backups. It must be a platform-writable directory,
	// never the application bundle or install directory.
	dataDir string
	mu      sync.Mutex
}

// New returns a service over a kernel. dataDir is created on first write.
func New(kernel Kernel, env Environment, dataDir string) *Service {
	return &Service{kernel: kernel, env: env, dataDir: dataDir}
}

func (s *Service) ledgerPath() string { return filepath.Join(s.dataDir, "mcp-ledger.json") }

type ledgerFile struct {
	Files map[string][]core.McpLedgerEntry `json:"files"`
}

func (s *Service) readLedger() (ledgerFile, error) {
	ledger := ledgerFile{Files: map[string][]core.McpLedgerEntry{}}
	data, err := os.ReadFile(s.ledgerPath())
	if errors.Is(err, os.ErrNotExist) {
		return ledger, nil
	}
	if err != nil {
		return ledger, err
	}
	if err := json.Unmarshal(data, &ledger); err != nil {
		return ledger, fmt.Errorf("mcp ledger: %w", err)
	}
	if ledger.Files == nil {
		ledger.Files = map[string][]core.McpLedgerEntry{}
	}
	return ledger, nil
}

func (s *Service) writeLedger(ledger ledgerFile) error {
	if err := os.MkdirAll(s.dataDir, 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(ledger, "", "  ")
	if err != nil {
		return err
	}
	temp, err := os.CreateTemp(s.dataDir, "mcp-ledger-*.tmp")
	if err != nil {
		return err
	}
	name := temp.Name()
	if _, err := temp.Write(data); err != nil {
		temp.Close()
		os.Remove(name)
		return err
	}
	if err := temp.Close(); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Rename(name, s.ledgerPath()); err != nil {
		os.Remove(name)
		return err
	}
	return nil
}

// capture reads every file of the project and attaches the ledger.
func (s *Service) capture(ctx context.Context, project string, ledger ledgerFile) (Library, error) {
	lib := Library{Project: project, captured: map[string]configfile.Snapshot{}}
	var readable []core.McpLibraryFile
	for _, file := range Locations(s.env, project) {
		file.Owned = nonNil(ledger.Files[file.ID])
		snapshot, err := capturePath(ctx, file.Path)
		if err == nil {
			var text *string
			if text, err = snapshot.Text(); err == nil {
				file.Content = text
				lib.captured[file.ID] = snapshot
				readable = append(readable, file)
			}
		}
		if err != nil {
			if ctx.Err() != nil {
				return lib, ctx.Err()
			}
			lib.ReadFailures = append(lib.ReadFailures, ReadFailure{File: file.ID, Path: file.Path, Err: err})
		}
		lib.Files = append(lib.Files, file)
	}
	lib.Files = readableOnly(lib.Files, readable)
	return lib, nil
}

func readableOnly(all, readable []core.McpLibraryFile) []core.McpLibraryFile {
	ok := map[string]bool{}
	for _, file := range readable {
		ok[file.ID] = true
	}
	var out []core.McpLibraryFile
	for _, file := range all {
		if ok[file.ID] {
			out = append(out, file)
		}
	}
	return out
}

func nonNil[T any](s []T) []T {
	if s == nil {
		return []T{}
	}
	return s
}

// capturePath reads one file through configfile, following a symbolic link the way the
// tools do: the link is kept and its target is read and replaced.
func capturePath(ctx context.Context, path string) (configfile.Snapshot, error) {
	target := resolveTarget(path)
	return configfile.Capture(ctx, filepath.Dir(target), filepath.Base(target), MaximumFileBytes)
}

// resolveTarget is the file a write must replace: the target of a symbolic link, else the
// path itself. A path that does not exist yet is returned as it is.
func resolveTarget(path string) string {
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		return resolved
	}
	return path
}

// Load reads every file and asks Core for the merged library. It starts no process and
// writes nothing. Call it off the window thread.
func (s *Service) Load(ctx context.Context, project string) (Library, error) {
	ledger, err := s.readLedger()
	if err != nil {
		return Library{}, err
	}
	lib, err := s.capture(ctx, project, ledger)
	if err != nil {
		return lib, err
	}
	lib.Snapshot, err = s.kernel.McpLibrarySnapshot(ctx, lib.Files)
	return lib, err
}

// WriteError is a batch that failed part of the way. Unrestored lists the files that could
// not be put back because something else changed them after the batch wrote them; those
// keep the other writer's content.
type WriteError struct {
	Path       string
	Err        error
	Unrestored []string
}

func (e *WriteError) Error() string {
	if len(e.Unrestored) > 0 {
		return fmt.Sprintf("write %s: %v (not restored: %v)", filepath.Base(e.Path), e.Err, e.Unrestored)
	}
	return fmt.Sprintf("write %s: %v", filepath.Base(e.Path), e.Err)
}

func (e *WriteError) Unwrap() error { return e.Err }

// ErrUnreadable reports that a write was refused because a file could not be read.
var ErrUnreadable = errors.New("an MCP configuration file could not be read")

// ErrSharedPath reports a plan that changes two ledger files stored in one path.
var ErrSharedPath = errors.New("two planned changes target the same file")

// Apply reads every file again, asks Core to plan intent, and, when the plan is ready,
// writes the changed files as one rollback batch and publishes the ledgers after the whole
// batch succeeded. An invalid or rejected plan writes nothing and is returned as it is.
func (s *Service) Apply(ctx context.Context, project string, intent core.McpBatchIntent) (core.McpBatchPlan, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	ledger, err := s.readLedger()
	if err != nil {
		return core.McpBatchPlan{}, err
	}
	lib, err := s.capture(ctx, project, ledger)
	if err != nil {
		return core.McpBatchPlan{}, err
	}
	if len(lib.ReadFailures) > 0 {
		return core.McpBatchPlan{}, ErrUnreadable
	}
	plan, err := s.kernel.McpBatchPlan(ctx, lib.Files, intent)
	if err != nil || plan.Status != "ready" {
		return plan, err
	}
	if err := s.publish(ctx, lib, plan.Changes); err != nil {
		return plan, err
	}
	for _, change := range plan.Changes {
		ledger.Files[change.File] = change.Owned
	}
	return plan, s.writeLedger(ledger)
}

type written struct {
	id      string
	path    string
	before  []byte
	hadFile bool
	after   []byte
}

// publish writes every changed file, backing each up first, and restores the ones already
// written when a later one fails.
func (s *Service) publish(ctx context.Context, lib Library, changes []core.McpBatchChange) error {
	paths := map[string]string{}
	for _, change := range changes {
		if !change.Changed || change.Content == nil {
			continue
		}
		snapshot := lib.captured[change.File]
		if previous, shared := paths[snapshot.Path()]; shared {
			return fmt.Errorf("%w: %s and %s", ErrSharedPath, previous, change.File)
		}
		paths[snapshot.Path()] = change.File
	}
	stamp := time.Now().UTC().Format("20060102T150405.000000000Z")
	var done []written
	for _, change := range changes {
		if !change.Changed || change.Content == nil {
			continue
		}
		snapshot := lib.captured[change.File]
		if err := s.backup(snapshot, stamp); err != nil {
			return s.rollback(ctx, done, &WriteError{Path: snapshot.Path(), Err: err})
		}
		content := []byte(*change.Content)
		if _, err := snapshot.Replace(ctx, content, nil); err != nil {
			return s.rollback(ctx, done, &WriteError{Path: snapshot.Path(), Err: err})
		}
		done = append(done, written{id: change.File, path: snapshot.Path(), before: snapshot.Bytes(), hadFile: snapshot.Exists(), after: content})
	}
	return nil
}

// backup copies the current file into the data directory before it is replaced. A failure
// aborts the write rather than risk losing the original.
func (s *Service) backup(snapshot configfile.Snapshot, stamp string) error {
	if !snapshot.Exists() {
		return nil
	}
	directory := filepath.Join(s.dataDir, "MCP Backups", stamp)
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(directory, filepath.Base(snapshot.Path())), snapshot.Bytes(), 0o600)
}

// rollback puts back the files written so far, newest first. A file whose bytes are no
// longer the ones the batch wrote was changed by someone else and is left alone.
func (s *Service) rollback(ctx context.Context, done []written, cause *WriteError) error {
	for i := len(done) - 1; i >= 0; i-- {
		w := done[i]
		// A cancelled batch must still be undone.
		restore := context.WithoutCancel(ctx)
		current, err := configfile.Capture(restore, filepath.Dir(w.path), filepath.Base(w.path), MaximumFileBytes)
		if err != nil || string(current.Bytes()) != string(w.after) {
			cause.Unrestored = append(cause.Unrestored, w.path)
			continue
		}
		if w.hadFile {
			_, err = current.Replace(restore, w.before, nil)
		} else {
			_, err = current.Remove(restore, nil)
		}
		if err != nil {
			cause.Unrestored = append(cause.Unrestored, w.path)
		}
	}
	return cause
}

// Probe lists a server's tools. The caller must have an explicit user action and, for a
// local command, the product's execution confirmation. It may start a process and blocks.
func (s *Service) Probe(ctx context.Context, definition core.McpServer) ([]core.McpTool, error) {
	return s.kernel.McpProbe(ctx, core.McpProbeRequest{
		Transport: definition.Transport, Command: definition.Command, Args: definition.Args,
		Env: definition.Env, URL: definition.URL, Headers: definition.Headers,
	})
}

// ToolPolicyPath is the file Core's tool policy edits for an agent: Codex's config.toml or
// Claude's user settings.json.
func (s *Service) ToolPolicyPath(agent string) string {
	if agent == "claude" {
		return s.env.ClaudeSettingsPath()
	}
	return s.env.CodexConfigPath()
}

type toolOwnership struct {
	Tools map[string][]string `json:"tools"`
}

func toolKey(path, server string) string { return path + "#" + server }

func (s *Service) toolsPath() string { return filepath.Join(s.dataDir, "mcp-tools.json") }

func (s *Service) readTools() toolOwnership {
	owned := toolOwnership{Tools: map[string][]string{}}
	if data, err := os.ReadFile(s.toolsPath()); err == nil {
		_ = json.Unmarshal(data, &owned)
	}
	if owned.Tools == nil {
		owned.Tools = map[string][]string{}
	}
	return owned
}

// ToolPolicy reads the switches of a server's tools under the agent's native rules. It does
// not write.
func (s *Service) ToolPolicy(ctx context.Context, agent, server string, tools []string) (core.McpToolPolicy, error) {
	path := s.ToolPolicyPath(agent)
	snapshot, err := capturePath(ctx, path)
	if err != nil {
		return core.McpToolPolicy{}, err
	}
	text, err := snapshot.Text()
	if err != nil {
		return core.McpToolPolicy{}, err
	}
	content := "{}"
	if agent == "codex" {
		content = ""
	}
	if text != nil {
		content = *text
	}
	return s.kernel.McpToolPolicy(ctx, core.McpToolPolicyRequest{
		Source: agent, Content: content, Server: server, Tools: tools, Owned: s.readTools().Tools[toolKey(path, server)],
	})
}

// SetTool turns one tool on or off and publishes the file. A rule Lithe did not write is
// reported not editable by Core and never relaxed. The exact tool names Lithe added are kept
// by native path and server.
func (s *Service) SetTool(ctx context.Context, agent, server string, tools []string, tool string, enabled bool) (core.McpToolPolicy, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	path := s.ToolPolicyPath(agent)
	snapshot, err := capturePath(ctx, path)
	if err != nil {
		return core.McpToolPolicy{}, err
	}
	text, err := snapshot.Text()
	if err != nil {
		return core.McpToolPolicy{}, err
	}
	content := "{}"
	if agent == "codex" {
		content = ""
	}
	if text != nil {
		content = *text
	}
	owned := s.readTools()
	policy, err := s.kernel.McpToolPolicy(ctx, core.McpToolPolicyRequest{
		Source: agent, Content: content, Server: server, Tools: tools, Owned: owned.Tools[toolKey(path, server)],
		Tool: tool, Enabled: &enabled,
	})
	if err != nil {
		return policy, err
	}
	if policy.Changed {
		if err := s.backup(snapshot, time.Now().UTC().Format("20060102T150405.000000000Z")); err != nil {
			return policy, err
		}
		if _, err := snapshot.Replace(ctx, []byte(policy.Content), nil); err != nil {
			return policy, err
		}
	}
	owned.Tools[toolKey(path, server)] = policy.Owned
	data, err := json.Marshal(owned)
	if err == nil {
		if err = os.MkdirAll(s.dataDir, 0o700); err == nil {
			err = os.WriteFile(s.toolsPath(), data, 0o600)
		}
	}
	return policy, err
}
