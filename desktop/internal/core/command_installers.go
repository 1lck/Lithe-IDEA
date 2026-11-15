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

// CommandInstaller is the summary of one commandInstallers[] entry.
type CommandInstaller struct {
	ID             string   `json:"id"`
	Commands       []string `json:"commands"`
	Tool           string   `json:"tool"`
	MinimumVersion *string  `json:"minimumVersion"`
	MayUseNetwork  bool     `json:"mayUseNetwork"`
	// Targets lists the declared targets, managed before toolDefault.
	Targets []string `json:"targets"`
}

// CommandInstallPlan is one installer expanded for the target the user chose. The host runs
// Tool's resolved executable with Arguments and Environment set over the tool's environment.
type CommandInstallPlan struct {
	Installer           string            `json:"installer"`
	Target              string            `json:"target"`
	Commands            []string          `json:"commands"`
	Tool                string            `json:"tool"`
	MinimumVersion      *string           `json:"minimumVersion"`
	MayUseNetwork       bool              `json:"mayUseNetwork"`
	TimeoutMilliseconds int64             `json:"timeoutMilliseconds"`
	Arguments           []string          `json:"arguments"`
	Environment         map[string]string `json:"environment"`
	// CommandDirectory is where a managed installation's commands land; nil for toolDefault,
	// whose directory the probes find.
	CommandDirectory *string                 `json:"commandDirectory"`
	DirectoryProbes  []CommandDirectoryProbe `json:"directoryProbes"`
}

// CommandDirectoryProbe is one run of the plan's tool whose output names the directory a
// toolDefault installation puts its commands in.
type CommandDirectoryProbe struct {
	Arguments []string `json:"arguments"`
}

// CommandInstallerRequirements lists the systemCommand launches of manifest and the installer
// of each command. It reads nothing and starts nothing.
func (c *Client) CommandInstallerRequirements(ctx context.Context, manifest json.RawMessage) (CommandRequirements, error) {
	const command = "plugins.commandInstallers.requirements"
	var result struct {
		Status       string                `json:"status"`
		Error        *MarketplaceRejection `json:"error"`
		Requirements *CommandRequirements  `json:"requirements"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest json.RawMessage `json:"manifest"`
	}{manifest}, &result); err != nil {
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
// directory the host made for a managed installation and must be empty for toolDefault.
func (c *Client) PlanCommandInstaller(ctx context.Context, manifest json.RawMessage, installerID, target, installDirectory string) (CommandInstallPlan, error) {
	const command = "plugins.commandInstallers.plan"
	var result struct {
		Status string                `json:"status"`
		Error  *MarketplaceRejection `json:"error"`
		Plan   *CommandInstallPlan   `json:"plan"`
	}
	if err := c.Execute(ctx, command, struct {
		Manifest         json.RawMessage `json:"manifest"`
		InstallerID      string          `json:"installerID"`
		Target           string          `json:"target"`
		InstallDirectory string          `json:"installDirectory,omitempty"`
	}{manifest, installerID, target, installDirectory}, &result); err != nil {
		return CommandInstallPlan{}, err
	}
	if result.Status == "rejected" && result.Error != nil {
		return CommandInstallPlan{}, result.Error
	}
	if result.Status != "ok" || result.Plan == nil || result.Plan.Installer != installerID || result.Plan.Target != target || len(result.Plan.Commands) == 0 || result.Plan.TimeoutMilliseconds <= 0 {
		return CommandInstallPlan{}, newParseError(command, "command installer plan returned an invalid outcome", "")
	}
	if (target == CommandInstallManaged) != (result.Plan.CommandDirectory != nil) {
		return CommandInstallPlan{}, newParseError(command, "command installer plan returned an invalid outcome", "")
	}
	return *result.Plan, nil
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
