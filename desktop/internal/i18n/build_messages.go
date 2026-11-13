package i18n

import "strconv"

// BuildMessages are the Run tool window's provider-backed build strings.
type BuildMessages struct {
	PluginsUnavailable string
	NoBuildSystems     string
	ChooseTask         string
	// ChooseTaskScope asks for a project or target when a task runs on one and none is inferred.
	ChooseTaskScope    string
	ProjectMissing     string
	TargetMissing      string
	ArgumentsRequired  string
	CommandUnsupported string
	Running            string
	Preparing          string
	Succeeded          string
	Exited             func(code int) string
	ExecutableMissing  string
	VersionTooOld      func(version, minimum string) string
	Cancelled          string
	Stopping           string
	Refresh            string
	Systems            string
	Projects           string
	Targets            string
	Tasks              string
	Output             string
	Stop               string
	EmptyOutput        string
	NoTasks            string
	NoProjects         string
	LoadingModel       string
	ModelFailed        func(error string) string
	// TestDiscoveryFailed is the line of the Discovered Tests section after discovery failed.
	TestDiscoveryFailed func(error string) string
	ProcessFailed       func(error string) string
	ToolchainGap        func(toolchain string) string
	RunSelected         string
	RunTarget           func(name string) string
}

func buildMessages(language Language) BuildMessages {
	return BuildMessages{
		PluginsUnavailable: Shared(language, "desktop.build.pluginsUnavailable"),
		NoBuildSystems:     Shared(language, "desktop.build.noBuildSystems"),
		ChooseTask:         Shared(language, "desktop.build.chooseTask"),
		ChooseTaskScope:    Shared(language, "desktop.build.chooseTaskScope"),
		ProjectMissing:     Shared(language, "desktop.build.projectMissing"),
		TargetMissing:      Shared(language, "desktop.build.targetMissing"),
		ArgumentsRequired:  Shared(language, "desktop.build.argumentsRequired"),
		CommandUnsupported: Shared(language, "desktop.build.commandUnsupported"),
		Running:            Shared(language, "desktop.build.running"),
		Preparing:          Shared(language, "desktop.build.preparing"),
		Succeeded:          Shared(language, "desktop.build.succeeded"),
		ExecutableMissing:  Shared(language, "desktop.build.executableMissing"),
		VersionTooOld: func(version, minimum string) string {
			return SharedFormat(language, "desktop.build.versionTooOld", map[string]string{"version": version, "minimum": minimum})
		},
		Exited: func(code int) string {
			return SharedFormat(language, "desktop.build.exited", map[string]string{"code": strconv.Itoa(code)})
		},
		Cancelled:    Shared(language, "desktop.build.cancelled"),
		Stopping:     Shared(language, "desktop.build.stopping"),
		Refresh:      Shared(language, "desktop.build.refresh"),
		Systems:      Shared(language, "desktop.build.systems"),
		Projects:     Shared(language, "desktop.build.projects"),
		Targets:      Shared(language, "desktop.build.targets"),
		Tasks:        Shared(language, "desktop.build.tasks"),
		Output:       Shared(language, "desktop.build.output"),
		Stop:         Shared(language, "desktop.build.stop"),
		EmptyOutput:  Shared(language, "desktop.build.emptyOutput"),
		NoTasks:      Shared(language, "desktop.build.noTasks"),
		NoProjects:   Shared(language, "desktop.build.noProjects"),
		LoadingModel: Shared(language, "desktop.build.loadingModel"),
		ModelFailed: func(reason string) string {
			return SharedFormat(language, "desktop.build.modelFailed", map[string]string{"error": reason})
		},
		TestDiscoveryFailed: func(reason string) string {
			return SharedFormat(language, "desktop.build.testDiscoveryFailed", map[string]string{"error": reason})
		},
		ProcessFailed: func(reason string) string {
			return SharedFormat(language, "desktop.build.processFailed", map[string]string{"error": reason})
		},
		ToolchainGap: func(toolchain string) string {
			return SharedFormat(language, "desktop.build.toolchainGap", map[string]string{"toolchain": toolchain})
		},
		RunSelected: Shared(language, "desktop.build.runSelected"),
		RunTarget: func(name string) string {
			return SharedFormat(language, "desktop.build.runTarget", map[string]string{"name": name})
		},
	}
}
