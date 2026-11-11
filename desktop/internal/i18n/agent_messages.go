package i18n

// AgentMessages are the Agent panel's words. Agent-returned text, option names
// and upstream diagnostics stay in their original language.
type AgentMessages struct {
	AgentLabel          string
	ProviderLabel       string
	Start               string
	Change              string
	Checking            string
	CheckAgain          string
	NoAgents            string
	NoProviders         string
	NotInstalled        string
	MissingKey          string
	ProviderUnsupported func(reason string) string
	ErrorStatus         func(message string) string
	ErrorProvider       func(message string) string

	Placeholder  string
	MessageLabel string
	Send         string
	Stop         string
	Stopping     string

	History                string
	NewChat                string
	Back                   string
	Refresh                string
	HistoryTitle           string
	HistoryLoading         string
	HistoryEmpty           string
	HistoryUnsupported     string
	HistoryLoadUnsupported string
	HistoryLimited         string
	HistoryFailed          string
	HistoryRestoreFailed   string
	Untitled               string
	Current                string
	ConfigModel            string
	ConfigThinking         string
	ConfigPermissions      string
	ConfigFailed           string

	StatusChecking          string
	StatusStarting          string
	StatusReady             string
	StatusWorking           string
	StatusStopping          string
	StatusFailed            string
	StatusWaitingPermission string
	StatusSignIn            string
	StatusSigningIn         string
	StatusRestoring         string
	StatusConfiguring       string

	Empty         string
	RoleUser      string
	RoleAssistant string

	PermissionTitle string
	PermissionTool  func(tool string) string
	Deny            string

	Dismiss                string
	ConnectionClosed       string
	ConnectionLost         string
	ErrorOverflow          string
	RequestFailed          string
	AuthenticationRequired string

	ErrorCredential      string
	ErrorDetection       string
	Install              string
	InstallCancel        string
	InstallCancelling    string
	InstallRetry         string
	InstallPreparing     string
	InstallDownloading   string
	InstallUpdating      string
	InstallWaiting       string
	InstallProgress      func(downloaded, speed, elapsed string) string
	InstallFailed        func(message string) string
	InstallFailedDetail  string
	InstallCancelled     string
	InstallTimedOut      string
	InstallProgressLost  string
	ErrorHome            string
	ErrorConfigRead      string
	ErrorInvalidConfig   string
	ErrorUnsupportedAuth string
	ErrorConnection      string
	ErrorSend            string
	ErrorPermission      string
	ErrorCancel          string
	ErrorSession         string

	Activity     AgentActivityMessages
	Card         AgentCardMessages
	Subscription AgentSubscriptionMessages
	Editor       AgentEditorMessages
	Provider     AgentProviderMessages
	Mode         AgentModeMessages
	HistoryMeta  AgentHistoryMetaMessages
	Process      AgentProcessMessages
	Header       AgentHeaderMessages
	Export       AgentExportMessages
}

func agentMessages(language Language) AgentMessages {
	return AgentMessages{
		Activity:      agentActivityMessages(language),
		Card:          agentCardMessages(language),
		Subscription:  agentSubscriptionMessages(language),
		Editor:        agentEditorMessages(language),
		Provider:      agentProviderMessages(language),
		Mode:          agentModeMessages(language),
		HistoryMeta:   agentHistoryMetaMessages(language),
		Process:       agentProcessMessages(language),
		Header:        agentHeaderMessages(language),
		Export:        agentExportMessages(language),
		AgentLabel:    Shared(language, "desktop.agent.setup.agent"),
		ProviderLabel: Shared(language, "desktop.agent.setup.provider"),
		Start:         Shared(language, "desktop.agent.setup.start"),
		Change:        Shared(language, "desktop.agent.setup.change"),
		Checking:      Shared(language, "desktop.agent.setup.checking"),
		CheckAgain:    Shared(language, "desktop.agent.setup.retry"),
		NoAgents:      Shared(language, "desktop.agent.setup.noAgents"),
		NoProviders:   Shared(language, "desktop.agent.setup.noProviders"),
		NotInstalled:  Shared(language, "desktop.agent.setup.notInstalled"),
		MissingKey:    Shared(language, "desktop.agent.setup.missingKey"),
		ProviderUnsupported: func(reason string) string {
			return SharedFormat(language, "desktop.agent.setup.unsupported", map[string]string{"reason": reason})
		},
		ErrorStatus: func(message string) string {
			return SharedFormat(language, "desktop.agent.error.status", map[string]string{"message": message})
		},
		ErrorProvider: func(message string) string {
			return SharedFormat(language, "desktop.agent.error.provider", map[string]string{"message": message})
		},

		Placeholder:  Shared(language, "desktop.agent.composer.placeholder"),
		MessageLabel: Shared(language, "desktop.agent.composer.label"),
		Send:         Shared(language, "desktop.agent.composer.send"),
		Stop:         Shared(language, "desktop.agent.composer.stop"),
		Stopping:     Shared(language, "desktop.agent.composer.stopping"),

		History:                Shared(language, "desktop.agent.toolbar.history"),
		NewChat:                Shared(language, "desktop.agent.toolbar.newChat"),
		Back:                   Shared(language, "desktop.agent.toolbar.back"),
		Refresh:                Shared(language, "desktop.agent.history.refresh"),
		HistoryTitle:           Shared(language, "desktop.agent.history.title"),
		HistoryLoading:         Shared(language, "desktop.agent.history.loading"),
		HistoryEmpty:           Shared(language, "desktop.agent.history.empty"),
		HistoryUnsupported:     Shared(language, "desktop.agent.history.unsupportedList"),
		HistoryLoadUnsupported: Shared(language, "desktop.agent.history.unsupportedLoad"),
		HistoryLimited:         Shared(language, "desktop.agent.history.limited"),
		HistoryFailed:          Shared(language, "desktop.agent.history.failed"),
		HistoryRestoreFailed:   Shared(language, "desktop.agent.history.restoreFailed"),
		Untitled:               Shared(language, "desktop.agent.history.untitled"),
		Current:                Shared(language, "desktop.agent.history.current"),
		ConfigModel:            Shared(language, "desktop.agent.config.model"),
		ConfigThinking:         Shared(language, "desktop.agent.config.thinking"),
		ConfigPermissions:      Shared(language, "desktop.agent.config.permissions"),
		ConfigFailed:           Shared(language, "desktop.agent.config.failed"),

		StatusChecking:          Shared(language, "desktop.agent.status.checking"),
		StatusStarting:          Shared(language, "desktop.agent.status.starting"),
		StatusReady:             Shared(language, "desktop.agent.status.ready"),
		StatusWorking:           Shared(language, "desktop.agent.status.working"),
		StatusStopping:          Shared(language, "desktop.agent.status.stopping"),
		StatusFailed:            Shared(language, "desktop.agent.status.failed"),
		StatusWaitingPermission: Shared(language, "desktop.agent.status.permission"),
		StatusSignIn:            Shared(language, "desktop.agent.status.signIn"),
		StatusSigningIn:         Shared(language, "desktop.agent.status.signingIn"),
		StatusRestoring:         Shared(language, "desktop.agent.status.restoring"),
		StatusConfiguring:       Shared(language, "desktop.agent.status.configuring"),

		Empty:         Shared(language, "desktop.agent.transcript.empty"),
		RoleUser:      Shared(language, "desktop.agent.transcript.user"),
		RoleAssistant: Shared(language, "desktop.agent.transcript.assistant"),

		PermissionTitle: Shared(language, "desktop.agent.permission.title"),
		PermissionTool: func(tool string) string {
			return SharedFormat(language, "desktop.agent.permission.tool", map[string]string{"tool": tool})
		},
		Deny: Shared(language, "desktop.agent.permission.deny"),

		Dismiss:                Shared(language, "desktop.agent.error.dismiss"),
		ConnectionClosed:       Shared(language, "desktop.agent.error.closed"),
		ConnectionLost:         Shared(language, "desktop.agent.error.lost"),
		ErrorOverflow:          Shared(language, "desktop.agent.error.overflow"),
		RequestFailed:          Shared(language, "desktop.agent.error.request"),
		AuthenticationRequired: Shared(language, "desktop.agent.auth.required"),

		ErrorCredential:    Shared(language, "desktop.agent.error.credential"),
		ErrorDetection:     Shared(language, "desktop.agent.error.detection"),
		Install:            Shared(language, "desktop.agent.install.button"),
		InstallCancel:      Shared(language, "desktop.agent.install.cancel"),
		InstallCancelling:  Shared(language, "desktop.agent.install.cancelling"),
		InstallRetry:       Shared(language, "desktop.agent.install.retry"),
		InstallPreparing:   Shared(language, "desktop.agent.install.preparing"),
		InstallDownloading: Shared(language, "desktop.agent.install.downloading"),
		InstallUpdating:    Shared(language, "desktop.agent.install.updating"),
		InstallWaiting:     Shared(language, "desktop.agent.install.waiting"),
		InstallProgress: func(downloaded, speed, elapsed string) string {
			return SharedFormat(language, "desktop.agent.install.progress", map[string]string{"downloaded": downloaded, "speed": speed, "elapsed": elapsed})
		},
		InstallFailed: func(message string) string {
			return SharedFormat(language, "desktop.agent.install.failed", map[string]string{"message": message})
		},
		InstallFailedDetail:  Shared(language, "desktop.agent.install.failedDetail"),
		InstallCancelled:     Shared(language, "desktop.agent.install.cancelled"),
		InstallTimedOut:      Shared(language, "desktop.agent.install.timedOut"),
		InstallProgressLost:  Shared(language, "desktop.agent.install.progressLost"),
		ErrorHome:            Shared(language, "desktop.agent.error.home"),
		ErrorConfigRead:      Shared(language, "desktop.agent.error.configRead"),
		ErrorInvalidConfig:   Shared(language, "desktop.agent.error.invalidConfig"),
		ErrorUnsupportedAuth: Shared(language, "desktop.agent.error.unsupportedAuth"),
		ErrorConnection:      Shared(language, "desktop.agent.error.connection"),
		ErrorSend:            Shared(language, "desktop.agent.error.send"),
		ErrorPermission:      Shared(language, "desktop.agent.error.permission"),
		ErrorCancel:          Shared(language, "desktop.agent.error.cancel"),
		ErrorSession:         Shared(language, "desktop.agent.error.session"),
	}
}
