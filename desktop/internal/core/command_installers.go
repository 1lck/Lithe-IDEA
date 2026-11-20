package core

import (
	"context"
	"encoding/json"
)

// Command installer targets, written as the contract's tokens.
const (
	// CommandInstallManaged installs into a directory the host owns for the plugin.
	CommandInstallManaged = "managed"
	// CommandInstallToolDefault installs wherever the tool puts commands when told nothing.
	CommandInstallToolDefault = "toolDefault"
)

// CommandRequirements is Core's answer to plugins.commandInstallers.requirements: every
// systemCommand launch of a manifest with the bare commands it names, and the installers that
// provide them.
type CommandRequirements struct {
	Consumers  []CommandConsumer  `json:"consumers"`
	Installers []CommandInstaller `json:"installers"`
}

// CommandConsumer is one systemCommand launch.
type CommandConsumer struct {
	// Kind is languageServer, buildProvider, vcsProvider, debugAdapter or backend.
	Kind string `json:"kind"`
	// ID is the language, build system, VCS or adapter ID; nil for the backend.
	ID       *string           `json:"id"`
	Commands []RequiredCommand `json:"commands"`
}

// RequiredCommand is one command a launch names, in the launch's order.
type RequiredCommand struct {
	Command string `json:"command"`
	// Installer is the ID of the installer that provides it; nil when none does.
	Installer *string `json:"installer"`
}

// CommandInstaller is the summary of one commandInstallers[] entry: a tool installer runs Tool,
// a download installer (commandInstallers 1) downloads a pinned archive and has no tool.
type CommandInstaller struct {
	ID       string   `json:"id"`
	Commands []string `json:"commands"`
	// Tool is the tool definition a tool installer runs; nil for a download installer.
	Tool           *string `json:"tool"`
	MinimumVersion *string `json:"minimumVersion"`
	// Download is the pinned version of a download installer; nil for a tool installer.
	Download      *CommandInstallerDownload `json:"download"`
	MayUseNetwork bool                      `json:"mayUseNetwork"`
	// Targets lists the declared targets, managed before toolDefault.
	Targets []string `json:"targets"`
}

// CommandInstallerDownload is what the requirements say of a download installer.
type CommandInstallerDownload struct {
	Version string `json:"version"`
}

// ToolID is the tool definition a tool installer runs, or "" for a download installer.
func (i CommandInstaller) ToolID() string {
	if i.Tool == nil {
		return ""
	}
	return *i.Tool
}

// CommandArchivePlatform is the host platform a download installer selects its archive for:
// os macos, windows or linux and arch arm64 or x86_64.
type CommandArchivePlatform = ManagedRuntimePlatform

// CommandInstallPlan is one installer expanded for the target the user chose. For a tool
// installer the host runs Tool's resolved executable with Arguments and Environment set over the
// tool's environment; for a download installer it downloads, checks and extracts Download.
type CommandInstallPlan struct {
	Installer           string            `json:"installer"`
	Target              string            `json:"target"`
	Commands            []string          `json:"commands"`
	Tool                *string           `json:"tool"`
	MinimumVersion      *string           `json:"minimumVersion"`
	MayUseNetwork       bool              `json:"mayUseNetwork"`
	TimeoutMilliseconds int64             `json:"timeoutMilliseconds"`
	Arguments           []string          `json:"arguments"`
	Environment         map[string]string `json:"environment"`
	// CommandDirectory is where a managed tool installation's commands land; nil for
	// toolDefault, whose directory the probes find, and for a download installation, whose
	// directory is below the extracted archive.
	CommandDirectory *string                 `json:"commandDirectory"`
	DirectoryProbes  []CommandDirectoryProbe `json:"directoryProbes"`
	// Download is the archive a download installation extracts; nil for a tool installation.
	Download *CommandInstallDownload `json:"download"`
}

// CommandInstallDownload is the archive Core selected for the host's platform. CacheKey names
// the extraction, which every change to what the archive holds replaces; mirrors do not count.
type CommandInstallDownload struct {
	Installer string `json:"installer"`
	Version   string `json:"version"`
	OS        string `json:"os"`
	Arch      string `json:"arch"`
	URL       string `json:"url"`
	// Mirrors are fallback URLs for the same bytes.
	Mirrors []string `json:"mirrors,omitempty"`
	// SHA256 is the lowercase digest the archive must have.
	SHA256 string `json:"sha256"`
	// Archive is zip or tar.gz.
	Archive string `json:"archive"`
	// StripPrefix is the slash-separated directory the archive's entries are below; empty
	// for none.
	StripPrefix string `json:"stripPrefix"`
	CacheKey    string `json:"cacheKey"`
	// CommandDirectory is where the commands are, slash-separated and relative to the
	// extracted root; empty for the root.
	CommandDirectory string `json:"commandDirectory"`
}

// CommandDirectoryProbe is one run of the plan's tool whose output names the directory a
// toolDefault installation puts its commands in.
type CommandDirectoryProbe struct {
	Arguments []string `json:"arguments"`
}

// CommandInstallerRequirements lists the systemCommand launches of manifest and the installer
// of each command. With platform, a download installer without an archive for it is left out;
// a host that installs downloads always passes its own. It reads nothing and starts nothing.
func (c *Client) CommandInstallerRequirements(ctx context.Context, manifest json.RawMessage, platform *CommandArchivePlatform) (CommandRequirements, error) {
	const command = "plugins.commandInstallers.requirements"
	var result struct {
		Status       string                `json:"status"`
		Error        *MarketplaceRejection `json:"error"`
		Requirements *CommandRequirements  `json:"requirements"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest json.RawMessage         `json:"manifest"`
		Platform *CommandArchivePlatform `json:"platform,omitempty"`
	}{manifest, platform}, &result); err != nil {
		return CommandRequirements{}, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return CommandRequirements{}, result.Error
	}
	if result.Status != "ok" || result.Requirements == nil {
		return CommandRequirements{}, newParseError(command, "command requirements returned an invalid outcome", "")
	}
	return *result.Requirements, nil
}

// PlanCommandInstaller expands installerID for target. installDirectory is the absolute
// directory the host made for a managed tool installation and must be empty for toolDefault
// and for a download installation, which needs platform to select its archive.
func (c *Client) PlanCommandInstaller(ctx context.Context, manifest json.RawMessage, installerID, target, installDirectory string, platform *CommandArchivePlatform) (CommandInstallPlan, error) {
	const command = "plugins.commandInstallers.plan"
	var result struct {
		Status string                `json:"status"`
		Error  *MarketplaceRejection `json:"error"`
		Plan   *CommandInstallPlan   `json:"plan"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest         json.RawMessage         `json:"manifest"`
		InstallerID      string                  `json:"installerID"`
		Target           string                  `json:"target"`
		InstallDirectory string                  `json:"installDirectory,omitempty"`
		Platform         *CommandArchivePlatform `json:"platform,omitempty"`
	}{manifest, installerID, target, installDirectory, platform}, &result); err != nil {
		return CommandInstallPlan{}, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return CommandInstallPlan{}, result.Error
	}
	if result.Status != "ok" || result.Plan == nil || result.Plan.Installer != installerID || result.Plan.Target != target || len(result.Plan.Commands) == 0 || result.Plan.TimeoutMilliseconds <= 0 {
		return CommandInstallPlan{}, newParseError(command, "command installer plan returned an invalid outcome", "")
	}
	if !result.Plan.consistent() {
		return CommandInstallPlan{}, newParseError(command, "command installer plan returned an invalid outcome", "")
	}
	return *result.Plan, nil
}

// consistent says the plan is one the host can carry out: a download installs into the managed
// target with nothing to run, and a tool installation has a command directory exactly when
// it is managed.
func (p *CommandInstallPlan) consistent() bool {
	if download := p.Download; download != nil {
		return p.Target == CommandInstallManaged && p.CommandDirectory == nil && p.Tool == nil &&
			len(p.Arguments) == 0 && len(p.Environment) == 0 && len(p.DirectoryProbes) == 0 &&
			download.Installer == p.Installer && download.URL != "" && download.SHA256 != "" &&
			download.CacheKey != "" && (download.Archive == "zip" || download.Archive == "tar.gz")
	}
	return p.Tool != nil && (p.Target == CommandInstallManaged) == (p.CommandDirectory != nil)
}

// CommandInstallerDefaultDirectory reads where a toolDefault installation of installerID puts
// its commands from the output of its directory probes, one per probe in plan order and nil
// for a probe that failed. ok is false when no probe named an absolute directory.
func (c *Client) CommandInstallerDefaultDirectory(ctx context.Context, manifest json.RawMessage, installerID string, outputs []*string) (directory string, ok bool, err error) {
	const command = "plugins.commandInstallers.defaultDirectory"
	if outputs == nil {
		// Core reads an absent or null list as malformed; no probes is an empty list.
		outputs = []*string{}
	}
	var result struct {
		Status    string                `json:"status"`
		Error     *MarketplaceRejection `json:"error"`
		Directory *string               `json:"directory"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest    json.RawMessage `json:"manifest"`
		InstallerID string          `json:"installerID"`
		Outputs     []*string       `json:"outputs"`
	}{manifest, installerID, outputs}, &result); err != nil {
		return "", false, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return "", false, result.Error
	}
	if result.Status != "ok" {
		return "", false, newParseError(command, "command installer default directory returned an invalid outcome", "")
	}
	if result.Directory == nil || *result.Directory == "" {
		return "", false, nil
	}
	return *result.Directory, true, nil
}
