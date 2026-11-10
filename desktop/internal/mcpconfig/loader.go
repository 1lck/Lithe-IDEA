package mcpconfig

import (
	"context"
	"os"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/store"
)

// Loader is what the MCP settings page calls. Every method blocks (file reads, Core, the
// network or a probe) and must run off the window thread.
type Loader struct {
	Service *Service
	Client  *core.Client
	// Project is the open project's root, or empty. Read per call.
	Project func() string
	// RegistryBase overrides RegistryBaseURL in tests.
	RegistryBase string
}

// NewLoader makes the loader of the running platform: the tools' real files under the
// user's home, and the ledger and backups under the client's own application data folder.
func NewLoader(client *core.Client) (*Loader, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	base, err := os.UserConfigDir()
	if err != nil {
		return nil, err
	}
	service := New(client, Environment{Home: home, Getenv: os.Getenv}, filepath.Join(base, store.Directory, "mcp"))
	return &Loader{Service: service, Client: client}, nil
}

func (l *Loader) project() string {
	if l.Project == nil {
		return ""
	}
	return l.Project()
}

// Load reads every native file and Core's merged view of them.
func (l *Loader) Load(ctx context.Context) (Library, error) {
	return l.Service.Load(ctx, l.project())
}

// Apply plans and publishes one library change.
func (l *Loader) Apply(ctx context.Context, intent core.McpBatchIntent) (core.McpBatchPlan, error) {
	return l.Service.Apply(ctx, l.project(), intent)
}

// Featured is Core's compile-time catalog; it makes no request.
func (l *Loader) Featured(ctx context.Context) (core.McpRegistryPage, error) {
	return l.Client.McpFeaturedRegistry(ctx)
}

// Search asks the official registry for one page and lets Core normalize it.
func (l *Loader) Search(ctx context.Context, query, cursor string) (core.McpRegistryPage, error) {
	base := l.RegistryBase
	if base == "" {
		base = RegistryBaseURL
	}
	body, err := FetchRegistry(ctx, base, query, cursor)
	if err != nil {
		return core.McpRegistryPage{}, err
	}
	return l.Client.McpParseRegistry(ctx, body)
}

// Probe lists a server's tools after the user's explicit detection action.
func (l *Loader) Probe(ctx context.Context, definition core.McpServer) ([]core.McpTool, error) {
	return l.Service.Probe(ctx, definition)
}

// ToolPolicy reads the tool switches of a server under an agent's native rules.
func (l *Loader) ToolPolicy(ctx context.Context, agent, server string, tools []string) (core.McpToolPolicy, error) {
	return l.Service.ToolPolicy(ctx, agent, server, tools)
}

// SetTool turns one tool on or off for an agent.
func (l *Loader) SetTool(ctx context.Context, agent, server string, tools []string, tool string, enabled bool) (core.McpToolPolicy, error) {
	return l.Service.SetTool(ctx, agent, server, tools, tool, enabled)
}

// CommandLine formats a command and arguments as one editable line.
func (l *Loader) CommandLine(ctx context.Context, command string, args []string) (string, error) {
	return l.Client.McpCommandLine(ctx, command, args)
}

// ParseCommandLine splits an edited line into command and arguments without a shell.
func (l *Loader) ParseCommandLine(ctx context.Context, line string) (string, []string, error) {
	return l.Client.McpParseCommandLine(ctx, line)
}
