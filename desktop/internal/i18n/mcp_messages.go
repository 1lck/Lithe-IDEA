package i18n

// MCPMessages are the words of the MCP Configuration settings page.
type MCPMessages struct {
	Title              string
	Intro              string
	Help               string
	Servers            string
	Empty              string
	Loading            string
	Add                string
	Edit               string
	Delete             string
	Reload             string
	Working            string
	Saved              string
	ConflictNote       string
	ProjectOnly        string
	Owned              string
	External           string
	Codex              string
	Claude             string
	Agents             string
	Name               string
	Transport          string
	Stdio              string
	Http               string
	Sse                string
	Command            string
	CommandHelp        string
	Url                string
	Env                string
	Headers            string
	SecretsHint        string
	Save               string
	Cancel             string
	AddTitle           string
	EditTitle          string
	DeleteTitle        string
	DeleteBody         string
	Registry           string
	Featured           string
	SearchPlaceholder  string
	Search             string
	Searching          string
	NoResults          string
	More               string
	AddFromRegistry    string
	DocsOnly           string
	Detect             string
	Detecting          string
	DetectConfirmTitle string
	DetectConfirmBody  string
	DetectContinue     string
	Tools              string
	NoTools            string
	ToolLocked         string
	SseUnsupported     string
	LoadFailed         func(reason string) string
	FileUnreadable     func(file string) string
	ParseFailed        func(file string) string
	WriteFailed        func(reason string) string
	SearchFailed       func(reason string) string
	DetectFailed       func(reason string) string
	ToolFailed         func(reason string) string
	// Issue is the words of one draft validation code from Core; unknown codes get a generic line.
	Issue func(code string) string
	// Rejection is the words of one batch rejection code from Core.
	Rejection func(code string) string
}

func mcpMessages(language Language) MCPMessages {
	return MCPMessages{
		Title:              Shared(language, "desktop.mcp.title"),
		Intro:              Shared(language, "desktop.mcp.intro"),
		Help:               Shared(language, "desktop.mcp.help"),
		Servers:            Shared(language, "desktop.mcp.servers"),
		Empty:              Shared(language, "desktop.mcp.empty"),
		Loading:            Shared(language, "desktop.mcp.loading"),
		Add:                Shared(language, "desktop.mcp.add"),
		Edit:               Shared(language, "desktop.mcp.edit"),
		Delete:             Shared(language, "desktop.mcp.delete"),
		Reload:             Shared(language, "desktop.mcp.reload"),
		Working:            Shared(language, "desktop.mcp.working"),
		Saved:              Shared(language, "desktop.mcp.saved"),
		ConflictNote:       Shared(language, "desktop.mcp.conflictNote"),
		ProjectOnly:        Shared(language, "desktop.mcp.projectOnly"),
		Owned:              Shared(language, "desktop.mcp.owned"),
		External:           Shared(language, "desktop.mcp.external"),
		Codex:              Shared(language, "desktop.mcp.codex"),
		Claude:             Shared(language, "desktop.mcp.claude"),
		Agents:             Shared(language, "desktop.mcp.agents"),
		Name:               Shared(language, "desktop.mcp.name"),
		Transport:          Shared(language, "desktop.mcp.transport"),
		Stdio:              Shared(language, "desktop.mcp.stdio"),
		Http:               Shared(language, "desktop.mcp.http"),
		Sse:                Shared(language, "desktop.mcp.sse"),
		Command:            Shared(language, "desktop.mcp.command"),
		CommandHelp:        Shared(language, "desktop.mcp.commandHelp"),
		Url:                Shared(language, "desktop.mcp.url"),
		Env:                Shared(language, "desktop.mcp.env"),
		Headers:            Shared(language, "desktop.mcp.headers"),
		SecretsHint:        Shared(language, "desktop.mcp.secretsHint"),
		Save:               Shared(language, "desktop.mcp.save"),
		Cancel:             Shared(language, "desktop.mcp.cancel"),
		AddTitle:           Shared(language, "desktop.mcp.addTitle"),
		EditTitle:          Shared(language, "desktop.mcp.editTitle"),
		DeleteTitle:        Shared(language, "desktop.mcp.deleteTitle"),
		DeleteBody:         Shared(language, "desktop.mcp.deleteBody"),
		Registry:           Shared(language, "desktop.mcp.registry"),
		Featured:           Shared(language, "desktop.mcp.featured"),
		SearchPlaceholder:  Shared(language, "desktop.mcp.searchPlaceholder"),
		Search:             Shared(language, "desktop.mcp.search"),
		Searching:          Shared(language, "desktop.mcp.searching"),
		NoResults:          Shared(language, "desktop.mcp.noResults"),
		More:               Shared(language, "desktop.mcp.more"),
		AddFromRegistry:    Shared(language, "desktop.mcp.addFromRegistry"),
		DocsOnly:           Shared(language, "desktop.mcp.docsOnly"),
		Detect:             Shared(language, "desktop.mcp.detect"),
		Detecting:          Shared(language, "desktop.mcp.detecting"),
		DetectConfirmTitle: Shared(language, "desktop.mcp.detectConfirmTitle"),
		DetectConfirmBody:  Shared(language, "desktop.mcp.detectConfirmBody"),
		DetectContinue:     Shared(language, "desktop.mcp.detectContinue"),
		Tools:              Shared(language, "desktop.mcp.tools"),
		NoTools:            Shared(language, "desktop.mcp.noTools"),
		ToolLocked:         Shared(language, "desktop.mcp.toolLocked"),
		SseUnsupported:     Shared(language, "desktop.mcp.sseUnsupported"),
		LoadFailed: func(reason string) string {
			return SharedFormat(language, "desktop.mcp.loadFailed", map[string]string{"reason": reason})
		},
		FileUnreadable: func(file string) string {
			return SharedFormat(language, "desktop.mcp.fileUnreadable", map[string]string{"file": file})
		},
		ParseFailed: func(file string) string {
			return SharedFormat(language, "desktop.mcp.parseFailed", map[string]string{"file": file})
		},
		WriteFailed: func(reason string) string {
			return SharedFormat(language, "desktop.mcp.writeFailed", map[string]string{"reason": reason})
		},
		SearchFailed: func(reason string) string {
			return SharedFormat(language, "desktop.mcp.searchFailed", map[string]string{"reason": reason})
		},
		DetectFailed: func(reason string) string {
			return SharedFormat(language, "desktop.mcp.detectFailed", map[string]string{"reason": reason})
		},
		ToolFailed: func(reason string) string {
			return SharedFormat(language, "desktop.mcp.toolFailed", map[string]string{"reason": reason})
		},
		Issue: func(code string) string {
			switch code {
			case "nameRequired":
				return Shared(language, "desktop.mcp.issue.nameRequired")
			case "nameInvalid":
				return Shared(language, "desktop.mcp.issue.nameInvalid")
			case "agentsRequired":
				return Shared(language, "desktop.mcp.issue.agentsRequired")
			case "duplicateKeys":
				return Shared(language, "desktop.mcp.issue.duplicateKeys")
			case "commandRequired":
				return Shared(language, "desktop.mcp.issue.commandRequired")
			case "commandMalformed":
				return Shared(language, "desktop.mcp.issue.commandMalformed")
			case "urlInvalid":
				return Shared(language, "desktop.mcp.issue.urlInvalid")
			case "bearerTokenRequired":
				return Shared(language, "desktop.mcp.issue.bearerTokenRequired")
			case "allowedDirectoriesRequired":
				return Shared(language, "desktop.mcp.issue.allowedDirectoriesRequired")
			}
			return Shared(language, "desktop.mcp.issue.other")
		},
		Rejection: func(code string) string {
			switch code {
			case "notOwned":
				return Shared(language, "desktop.mcp.rejected.notOwned")
			case "externallyModified":
				return Shared(language, "desktop.mcp.rejected.externallyModified")
			case "agentHasNoGlobalConfiguration":
				return Shared(language, "desktop.mcp.rejected.agentHasNoGlobalConfiguration")
			}
			return Shared(language, "desktop.mcp.rejected.other")
		},
	}
}
