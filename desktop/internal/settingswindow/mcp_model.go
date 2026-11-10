package settingswindow

import (
	"context"
	"net/url"
	"strings"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/mcpconfig"
	"github.com/vivaui/viva/ui"
)

// This file holds the state of the MCP Configuration page (AI group). It shows the MCP servers
// the user's Codex and Claude Code configuration files really contain, edits them in place and
// writes them back, and never keeps a shadow copy: every change is planned by Core against the
// current file text, published atomically, and read again. The screen is in mcp_view.go.

// MCPLoader is what the page needs from the platform. Every method blocks and runs off the
// window thread. *mcpconfig.Loader implements it.
type MCPLoader interface {
	Load(ctx context.Context) (mcpconfig.Library, error)
	Apply(ctx context.Context, intent core.McpBatchIntent) (core.McpBatchPlan, error)
	Featured(ctx context.Context) (core.McpRegistryPage, error)
	Search(ctx context.Context, query, cursor string) (core.McpRegistryPage, error)
	Probe(ctx context.Context, definition core.McpServer) ([]core.McpTool, error)
	ToolPolicy(ctx context.Context, agent, server string, tools []string) (core.McpToolPolicy, error)
	SetTool(ctx context.Context, agent, server string, tools []string, tool string, enabled bool) (core.McpToolPolicy, error)
	CommandLine(ctx context.Context, command string, args []string) (string, error)
	ParseCommandLine(ctx context.Context, line string) (string, []string, error)
}

// mcpAgents are the agents a server can be enabled for, in the order they are shown.
var mcpAgents = []string{"codex", "claude"}

// mcpMask stands for an environment or header value in the editor: secrets are never echoed.
// A line that still holds the mask keeps the stored value.
const mcpMask = "••••••••"

// job is one background request of the page, run as a page Effect. start replaces the one
// before it, so the result of a replaced request never arrives; take returns a finished
// result on the window thread at the start of a paint.
type job[T any] struct {
	effect *ui.EffectState[T, int]
	key    int
	run    func(context.Context) (T, error)
	busy   bool
	err    error
}

func newJob[T any]() *job[T] {
	j := &job[T]{}
	j.effect = ui.NewEffect[T, int](func(ctx context.Context) (T, error) { return j.run(ctx) })
	return j
}

func (j *job[T]) start(run func(context.Context) (T, error)) {
	j.run, j.busy, j.err = run, true, nil
	j.key++
}

func (j *job[T]) take() (T, bool) {
	value, err, ok := j.effect.Take()
	if !ok {
		var zero T
		return zero, false
	}
	j.busy, j.err = false, err
	return value, err == nil
}

func (j *job[T]) declare(c ui.C) {
	if j.key != 0 {
		ui.Effect(c, j.effect, j.key)
	}
}

// mcpApplied is the outcome of a write.
type mcpApplied struct {
	plan core.McpBatchPlan
}

// mcpSearched is one page of registry results.
type mcpSearched struct {
	page   core.McpRegistryPage
	append bool
}

// mcpProbed is a detection result with each agent's switches for the tools.
type mcpProbed struct {
	row      string
	tools    []core.McpTool
	policies map[string]core.McpToolPolicy
	// failed is a per-agent failure to read the policy; the others stay usable.
	failed map[string]error
}

// mcpToolSet is the result of switching one tool.
type mcpToolSet struct {
	row    string
	agent  string
	policy core.McpToolPolicy
}

// mcpEditor is the open add/edit dialog.
type mcpEditor struct {
	open bool
	// original is the entry as the user saw it; nil when adding. Its source hashes are the
	// precondition of the save.
	original *core.McpOriginal
	// stored are the values of the entry being edited, so a masked line keeps its value.
	storedEnv, storedHeaders []core.McpEntry
	name, command, url       ui.Field
	env, headers             ui.Field
	transport                string
	agents                   map[string]bool
	setup                    string
	// issues and rejection are what the last attempt to save was refused for.
	issues    []core.McpDraftIssue
	rejection *core.McpBatchRejection
}

// mcpState is the page's state. Only the window thread touches the fields.
type mcpState struct {
	loader MCPLoader

	load     *job[mcpconfig.Library]
	apply    *job[mcpApplied]
	featured *job[core.McpRegistryPage]
	search   *job[mcpSearched]
	probe    *job[mcpProbed]
	toolSet  *job[mcpToolSet]

	started bool
	library mcpconfig.Library
	loaded  bool

	featuredPage  core.McpRegistryPage
	searchPage    core.McpRegistryPage
	searched      bool
	query         ui.Field
	searchedQuery string

	editor mcpEditor
	// confirmDelete and confirmProbe are the rows a modal asks about.
	confirmDelete string
	confirmProbe  string
	// outcome is what the last write reported, shown under the list.
	outcome  *core.McpBatchPlan
	writeErr error
	probed   map[string]mcpProbed
	// probeRow is the row the last detection was started for.
	probeRow  string
	probeErr  map[string]error
	toolError error
}

func newMCPState(loader MCPLoader) *mcpState {
	s := &mcpState{loader: loader, probed: map[string]mcpProbed{}, probeErr: map[string]error{}}
	if loader != nil {
		s.load = newJob[mcpconfig.Library]()
		s.apply = newJob[mcpApplied]()
		s.featured = newJob[core.McpRegistryPage]()
		s.search = newJob[mcpSearched]()
		s.probe = newJob[mcpProbed]()
		s.toolSet = newJob[mcpToolSet]()
	}
	return s
}

// begin starts the first load the first time the page is drawn. Opening the page reads the
// files and the compile-time catalog and writes nothing.
func (s *mcpState) begin() {
	if s.loader == nil || s.started {
		return
	}
	s.started = true
	s.reload()
	s.featured.start(func(ctx context.Context) (core.McpRegistryPage, error) { return s.loader.Featured(ctx) })
}

// reload reads every native file again.
func (s *mcpState) reload() {
	loader := s.loader
	s.load.start(func(ctx context.Context) (mcpconfig.Library, error) { return loader.Load(ctx) })
}

// take applies finished work at the start of a paint.
func (s *mcpState) take() {
	if s.loader == nil {
		return
	}
	if lib, ok := s.load.take(); ok {
		s.library, s.loaded = lib, true
	}
	if applied, ok := s.apply.take(); ok {
		plan := applied.plan
		s.outcome = &plan
		s.writeErr = nil
		switch plan.Status {
		case "ready":
			s.editor.open = false
			s.probed = map[string]mcpProbed{}
		case "invalid":
			s.editor.issues = plan.Issues
		case "rejected":
			s.editor.rejection = plan.Rejection
		}
		// Whatever the outcome, the files are the truth: read them again.
		s.reload()
	} else if s.apply.err != nil {
		s.writeErr = s.apply.err
		s.reload()
	}
	if page, ok := s.featured.take(); ok {
		s.featuredPage = page
	}
	if result, ok := s.search.take(); ok {
		if result.append {
			s.searchPage.Entries = append(s.searchPage.Entries, result.page.Entries...)
			s.searchPage.NextCursor = result.page.NextCursor
		} else {
			s.searchPage = result.page
		}
	}
	if result, ok := s.probe.take(); ok {
		s.probed[result.row] = result
		delete(s.probeErr, result.row)
	}
	if result, ok := s.toolSet.take(); ok {
		probed := s.probed[result.row]
		if probed.policies == nil {
			probed.policies = map[string]core.McpToolPolicy{}
		}
		probed.policies[result.agent] = result.policy
		s.probed[result.row] = probed
		s.toolError = nil
	} else if s.toolSet.err != nil {
		s.toolError = s.toolSet.err
	}
}

// declare keeps the requests that are out alive in every paint.
func (s *mcpState) declare(c ui.C) {
	if s.loader == nil {
		return
	}
	s.load.declare(c)
	s.apply.declare(c)
	s.featured.declare(c)
	s.search.declare(c)
	s.probe.declare(c)
	s.toolSet.declare(c)
}

// working says a write or a read is under way, so the page offers no second one.
func (s *mcpState) working() bool {
	return s.load.busy || s.apply.busy
}

// agentOf is the agent whose global file a ledger file ID names, empty for any other file.
func agentOf(file string) string {
	switch file {
	case "codex|global|":
		return "codex"
	case "claude|global|":
		return "claude"
	}
	return ""
}

// enabledFor says whether the row has an entry in the agent's global file.
func enabledFor(row core.McpLibraryRow, agent string) bool {
	for _, source := range row.Sources {
		if agentOf(source.File) == agent {
			return true
		}
	}
	return false
}

// globalFiles are the global files the row is stored in.
func globalFiles(row core.McpLibraryRow) []string {
	var files []string
	for _, source := range row.Sources {
		if agentOf(source.File) != "" {
			files = append(files, source.File)
		}
	}
	return files
}

// originalOf captures the entry as it is now, for the save's precondition.
func originalOf(row core.McpLibraryRow) *core.McpOriginal {
	original := &core.McpOriginal{Name: row.Definition.Name}
	for _, source := range row.Sources {
		if agentOf(source.File) == "" {
			continue
		}
		original.Sources = append(original.Sources, core.McpOriginalSource{File: source.File, SourceHash: source.SourceHash, OwnedByLithe: source.OwnedByLithe})
	}
	return original
}

// summary is what a row shows of a server: the command, or the address without credentials.
// The arguments are never shown, as they can hold tokens.
func summary(definition core.McpServer) string {
	if definition.Transport == "stdio" {
		return definition.Command
	}
	address, err := url.Parse(definition.URL)
	if err != nil || address.Host == "" {
		return ""
	}
	address.User, address.RawQuery, address.Fragment = nil, "", ""
	return address.String()
}

// formatEntries shows environment variables or headers for editing, one per line, with the
// value masked.
func formatEntries(entries []core.McpEntry, separator string) string {
	var lines []string
	for _, entry := range entries {
		lines = append(lines, entry.Key+separator+mcpMask)
	}
	return strings.Join(lines, "\n")
}

// parseEntries reads the lines the user edited. A value that is still the mask keeps the
// stored value of the key, so an untouched secret is written back unchanged.
func parseEntries(text, separator string, stored []core.McpEntry) []core.McpEntry {
	kept := map[string]string{}
	for _, entry := range stored {
		kept[entry.Key] = entry.Value
	}
	var entries []core.McpEntry
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		key, value, _ := strings.Cut(line, separator)
		key, value = strings.TrimSpace(key), strings.TrimSpace(value)
		if value == mcpMask {
			if old, ok := kept[key]; ok {
				value = old
			}
		}
		entries = append(entries, core.McpEntry{Key: key, Value: value})
	}
	return entries
}

// openEditor opens the editor on a row (edit) or on a discovery draft or nothing (add).
// format turns a command and its arguments into the one editable line.
func (s *mcpState) openEditor(row *core.McpLibraryRow, draft *core.McpServer, setup string, format func(command string, args []string) string) {
	e := &s.editor
	*e = mcpEditor{open: true, transport: "stdio", agents: map[string]bool{}, setup: setup}
	definition := draft
	if row != nil {
		definition = &row.Definition
		e.original = originalOf(*row)
		for _, agent := range mcpAgents {
			e.agents[agent] = enabledFor(*row, agent)
		}
	}
	if definition == nil {
		return
	}
	e.name.SetText(definition.Name)
	e.transport = definition.Transport
	e.url.SetText(definition.URL)
	e.storedEnv, e.storedHeaders = definition.Env, definition.Headers
	e.env.SetText(formatEntries(definition.Env, "="))
	e.headers.SetText(formatEntries(definition.Headers, ": "))
	if definition.Transport == "stdio" {
		e.command.SetText(format(definition.Command, definition.Args))
	}
}

// mcpDraftInput is the editor's text and choices, copied on the window thread so the
// background save works from values nothing else changes.
type mcpDraftInput struct {
	name, command, url, env, headers, transport, setup string
	agents                                             []string
	storedEnv, storedHeaders                           []core.McpEntry
	original                                           *core.McpOriginal
}

func (e *mcpEditor) input() mcpDraftInput {
	in := mcpDraftInput{
		name: e.name.Text(), command: e.command.Text(), url: strings.TrimSpace(e.url.Text()),
		env: e.env.Text(), headers: e.headers.Text(), transport: e.transport, setup: e.setup,
		storedEnv: e.storedEnv, storedHeaders: e.storedHeaders, original: e.original,
	}
	for _, agent := range mcpAgents {
		if e.agents[agent] {
			in.agents = append(in.agents, agent)
		}
	}
	return in
}

// intent builds the Core save intent. The command line is split by Core, never by a shell.
// A line Core cannot split is reported as an invalid command field.
func (in mcpDraftInput) intent(ctx context.Context, loader MCPLoader) (core.McpBatchIntent, *core.McpBatchPlan) {
	draft := core.McpDraft{
		Name: in.name, Transport: in.transport, URL: in.url, EnabledAgents: in.agents, Setup: in.setup,
		Env: parseEntries(in.env, "=", in.storedEnv), Headers: parseEntries(in.headers, ":", in.storedHeaders),
	}
	if in.transport == "stdio" {
		command, args, err := loader.ParseCommandLine(ctx, in.command)
		if err != nil {
			return core.McpBatchIntent{}, &core.McpBatchPlan{Status: "invalid", Issues: []core.McpDraftIssue{{Field: "command", Code: "commandMalformed"}}}
		}
		draft.Command, draft.Arguments = command, args
	}
	return core.McpBatchIntent{Kind: "save", Draft: &draft, Original: in.original}, nil
}
