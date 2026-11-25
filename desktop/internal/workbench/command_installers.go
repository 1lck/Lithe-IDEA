package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/marketplace"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// commandProbeTimeout bounds one directory probe of a toolDefault installation. A probe only
// prints a directory, such as go env GOBIN.
const commandProbeTimeout = 10 * time.Second

// maxCommandProbeOutput bounds what a directory probe may print. A longer output names no
// directory, so the probe counts as failed.
const maxCommandProbeOutput = 64 << 10

// maxCommandOutputLine bounds one line of an installation's output the install dialog shows;
// the rest of a longer line is dropped.
const maxCommandOutputLine = 4096

// settingsCommandInstalls is the settings window's settingswindow.CommandInstaller. It looks
// the commands of the plugins' systemCommand launches up the way those launches do, and runs
// the installer a plugin declares (commandInstallers[], API-23) once the user confirms one.
// Core expands every installer, selects a download's archive and names the directories; the
// host resolves and runs a tool, or downloads, checks and extracts the archive, then checks
// that the commands landed and records where.
type settingsCommandInstalls struct{ app *App }

// archivePlatform is the platform Core selects a download installer's archive for. It is
// passed on every call, so an installer without an archive for this host is never offered.
func archivePlatform() *core.CommandArchivePlatform {
	platform := pluginservice.ArchivePlatform()
	return &platform
}

var _ settingswindow.CommandInstaller = settingsCommandInstalls{}

// manifest reads the manifest of the enabled plugin pluginID.
func (s settingsCommandInstalls) manifest(ctx context.Context, pluginID string) (json.RawMessage, error) {
	a := s.app
	if a.plugins == nil {
		return nil, errors.New("the plugin host is not available")
	}
	entries, err := a.plugins.Manager.Installed()
	if err != nil {
		return nil, err
	}
	entries = slices.DeleteFunc(entries, func(entry pluginmanager.Entry) bool { return entry.Installed.ID != pluginID })
	plugins, err := a.plugins.ToolchainPlugins(ctx, entries)
	for _, plugin := range plugins {
		if plugin.PluginID == pluginID {
			return plugin.Manifest, nil
		}
	}
	if err != nil {
		return nil, err
	}
	return nil, fmt.Errorf("plugin %s is not enabled", pluginID)
}

// Missing asks Core for the plugin's systemCommand launches and looks each one's commands up
// as its launch does: the debug adapter's lookup for a debug adapter, the plugin runner's for
// everything else, both of which add the directories recorded for the plugin to PATH.
func (s settingsCommandInstalls) Missing(ctx context.Context, pluginID string) (_ []settingswindow.MissingCommand, err error) {
	// A failed check leaves the cards without install buttons, which the window falls back to.
	defer func() {
		// log-exempt: 用户取消：设置窗口关闭或换了插件，检测结果不再需要。
		if err != nil && !errors.Is(err, context.Canceled) {
			s.app.backgroundFailedIn(ctx, "plugin_command_check", err)
		}
	}()
	manifest, err := s.manifest(ctx, pluginID)
	if err != nil {
		return nil, err
	}
	requirements, err := s.app.kernel.CommandInstallerRequirements(ctx, manifest, archivePlatform())
	if err != nil {
		return nil, err
	}
	installers := make(map[string]core.CommandInstaller, len(requirements.Installers))
	for _, installer := range requirements.Installers {
		installers[installer.ID] = installer
	}
	var missing []settingswindow.MissingCommand
	tools := sync.OnceValue(func() map[string]string { return s.toolNames(ctx) })
	for _, consumer := range requirements.Consumers {
		commands := make([]string, 0, len(consumer.Commands))
		installerID := ""
		for _, required := range consumer.Commands {
			commands = append(commands, required.Command)
			if installerID == "" && required.Installer != nil {
				installerID = *required.Installer
			}
		}
		if len(commands) == 0 || s.found(ctx, pluginID, consumer.Kind, commands) {
			continue
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		entry := settingswindow.MissingCommand{Kind: commandConsumerCapability(consumer.Kind), Commands: commands}
		if consumer.ID != nil {
			entry.ID = *consumer.ID
		}
		if installer, ok := installers[installerID]; ok {
			entry.Installer = installer.ID
			if installer.Tool != nil {
				entry.Tool = toolName(tools(), *installer.Tool)
			}
		}
		missing = append(missing, entry)
	}
	return missing, nil
}

// found reports whether a launch of kind finds one of commands. Only a launch that would fail
// for want of a command counts as missing; any other failure is not one an installer fixes.
func (s settingsCommandInstalls) found(ctx context.Context, pluginID, kind string, commands []string) bool {
	var err error
	if kind == "debugAdapter" {
		lookup := s.app.installedCommands().Lookup(pluginID, func(name string) (string, error) { return debugLookupCommand(ctx, name) })
		_, err = pluginhost.ResolveCommand(commands, lookup)
	} else {
		_, err = s.app.plugins.Backend.ResolveCommand(pluginID, commands)
	}
	var missing *pluginhost.CommandMissingError
	return !errors.As(err, &missing)
}

// commandConsumerCapability is the capability card a launch of Core's consumer kind belongs
// to; empty for the backend, which has no card.
func commandConsumerCapability(kind string) string {
	switch kind {
	case "languageServer":
		return settingswindow.CapabilityLanguageServer
	case "buildProvider":
		return settingswindow.CapabilityBuildSystem
	case "vcsProvider":
		return settingswindow.CapabilityVersionControl
	case "debugAdapter":
		return settingswindow.CapabilityDebugger
	}
	return ""
}

// toolNames are the display names of the enabled plugins' tool definitions by ID; nil when
// the registry cannot be read, which shows the IDs.
func (s settingsCommandInstalls) toolNames(ctx context.Context) map[string]string {
	const operation = "command_installer_tool_discovery"
	manifests, _, err := s.app.usableToolchainManifests(ctx, operation)
	if err != nil {
		if ctx.Err() == nil {
			s.app.backgroundFailedIn(ctx, operation, err)
		}
		return nil
	}
	if len(manifests) == 0 {
		return nil
	}
	registry, err := s.app.kernel.ToolchainRegistryOf(ctx, manifests)
	if err != nil {
		if ctx.Err() == nil {
			s.app.backgroundFailedIn(ctx, operation, err)
		}
		return nil
	}
	names := make(map[string]string, len(registry.Definitions))
	for _, entry := range registry.Definitions {
		if entry.Definition.DisplayName != "" {
			names[entry.Definition.ID] = entry.Definition.DisplayName
		}
	}
	return names
}

func toolName(names map[string]string, id string) string {
	if name := names[id]; name != "" {
		return name
	}
	return id
}

// Offer resolves the installer's tool and expands each of its targets, running a toolDefault
// target's directory probes to find where it would install. A download installer has no tool:
// its offer names the archive Core selected for this host.
func (s settingsCommandInstalls) Offer(ctx context.Context, pluginID, installerID string) (_ settingswindow.CommandInstallOffer, err error) {
	// The card's Install button is the action; its operation travels in ctx, since the settings
	// worker must not touch the window thread's operation.
	ctx = s.app.performedIn(ctx, "plugin.commandInstaller.offer", surfaceButton)
	defer func() { (settingsToolchains{app: s.app}).recordFailure(ctx, "plugin_command_install_offer", err) }()
	session, _, err := s.open(ctx, pluginID, installerID)
	if err != nil {
		return settingswindow.CommandInstallOffer{}, err
	}
	defer session.close()
	if session.installer.Download != nil {
		return session.downloadOffer(ctx)
	}
	offer := settingswindow.CommandInstallOffer{
		Installer:     installerID,
		Commands:      session.installer.Commands,
		Tool:          toolName(s.toolNames(ctx), session.installer.ToolID()),
		Executable:    session.selection.Executable,
		MayUseNetwork: session.installer.MayUseNetwork,
	}
	for _, target := range session.installer.Targets {
		prepared, err := session.prepare(ctx, target)
		if err != nil {
			return settingswindow.CommandInstallOffer{}, err
		}
		if offer.Timeout == 0 {
			offer.Timeout = prepared.timeout()
		}
		offer.Targets = append(offer.Targets, settingswindow.CommandInstallTarget{
			Target:      target,
			CommandLine: quoteArguments(append([]string{session.selection.Executable}, prepared.plan.Arguments...)),
			Environment: environmentLines(prepared.plan.Environment),
			Directory:   prepared.directory,
		})
	}
	return offer, nil
}

// downloadOffer is the offer of a download installer: the archive's version, URL and digest,
// and the managed directory it extracts below, its only target.
func (s *commandInstallSession) downloadOffer(ctx context.Context) (settingswindow.CommandInstallOffer, error) {
	prepared, err := s.prepare(ctx, core.CommandInstallManaged)
	if err != nil {
		return settingswindow.CommandInstallOffer{}, err
	}
	download := prepared.plan.Download
	return settingswindow.CommandInstallOffer{
		Installer:     s.installer.ID,
		Commands:      s.installer.Commands,
		MayUseNetwork: s.installer.MayUseNetwork,
		Timeout:       prepared.timeout(),
		Download: &settingswindow.CommandInstallDownload{
			Version: download.Version, URL: download.URL, Mirrors: download.Mirrors, SHA256: download.SHA256,
		},
		Targets: []settingswindow.CommandInstallTarget{{Target: core.CommandInstallManaged, Directory: prepared.directory}},
	}, nil
}

// environmentLines is an installation's environment as sorted NAME=value lines.
func environmentLines(environment map[string]string) []string {
	lines := make([]string, 0, len(environment))
	for name, value := range environment {
		lines = append(lines, name+"="+value)
	}
	sort.Strings(lines)
	return lines
}

// Install runs the installer for target and records where its commands landed, so the
// plugin's later launches find them. A tool's output goes to output; a download reports its
// phases to progress. The attempt is recorded on the plugin's host channel; a cancelled one is
// not.
func (s settingsCommandInstalls) Install(ctx context.Context, pluginID, installerID, target string, output func(string), progress func(pluginruntime.Progress)) (_ string, err error) {
	// The dialog's Install button is the action; the attempt and the installer's tool run under
	// its operation.
	ctx = s.app.performedIn(ctx, "plugin.commandInstaller.install", surfaceButton)
	defer func() { (settingsToolchains{app: s.app}).recordFailure(ctx, "plugin_command_install", err) }()
	attempt := core.StartPluginAttempt(pluginID, core.OperationCommandInstallerInstall, core.OriginOf(ctx).Operation)
	defer attempt.Abandon()
	directory, stage, err := s.install(ctx, pluginID, installerID, target, output, progress)
	if s.app.plugins != nil {
		s.app.plugins.EndAttempt(ctx, attempt, stage, err)
	}
	return directory, err
}

func (s settingsCommandInstalls) install(ctx context.Context, pluginID, installerID, target string, output func(string), progress func(pluginruntime.Progress)) (string, core.PluginStage, error) {
	session, stage, err := s.open(ctx, pluginID, installerID)
	if err != nil {
		return "", stage, err
	}
	defer session.close()
	if !slices.Contains(session.installer.Targets, target) {
		return "", core.StagePlan, fmt.Errorf("installer %s has no target %s", installerID, target)
	}
	prepared, err := session.prepare(ctx, target)
	if err != nil {
		return "", core.StagePlan, err
	}
	if prepared.plan.Download != nil {
		return session.download(ctx, prepared, progress)
	}
	if prepared.directory == "" {
		return "", core.StagePlan, fmt.Errorf("no directory probe of installer %s named where it installs", installerID)
	}
	if prepared.installDirectory != "" {
		if err := os.MkdirAll(prepared.installDirectory, 0o755); err != nil {
			return "", core.StagePlan, err
		}
	}
	timeout := prepared.timeout()
	run, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	lines := &commandOutputLines{send: output}
	process, err := buildprocess.Start(run, buildprocess.Spec{
		Kind:             processledger.KindProcess,
		Executable:       session.selection.Executable,
		Arguments:        prepared.plan.Arguments,
		WorkingDirectory: session.directory,
		Environment:      applyToolchainSelection(prepared.plan.Environment, session.selection),
	}, lines.write)
	if err != nil {
		return "", core.StageLaunch, err
	}
	waitErr := process.Wait()
	lines.flush()
	if err := ctx.Err(); err != nil {
		// The user cancelled, which is never recorded.
		return "", core.StageExit, err
	}
	if run.Err() != nil {
		return "", core.StageTimeout, &pluginhost.CommandInstallError{Code: pluginhost.CommandInstallTimedOutCode, Timeout: timeout}
	}
	if waitErr != nil {
		code := -1
		var exit *exec.ExitError
		if errors.As(waitErr, &exit) {
			code = exit.ExitCode()
		}
		return "", core.StageExit, &pluginhost.CommandInstallError{Code: pluginhost.CommandInstallFailedCode, ExitCode: code}
	}
	var absent []string
	for _, command := range prepared.plan.Commands {
		if _, err := pluginhost.CommandInDirectory(prepared.directory, command); err != nil {
			absent = append(absent, command)
		}
	}
	if len(absent) > 0 {
		return "", core.StageDecode, &pluginhost.CommandInstallError{Code: pluginhost.CommandInstallCommandsMissingCode, Commands: absent, Directory: prepared.directory}
	}
	// A record that cannot be written leaves the commands where later launches do not look,
	// which is the same outcome for them as commands missing from the directory.
	if err := s.app.plugins.Commands.Record(pluginID, pluginhost.CommandInstallation{Installer: installerID, Target: target, Directory: prepared.directory}); err != nil {
		return "", core.StageDecode, err
	}
	return prepared.directory, "", nil
}

// download fetches the archive of a download plan, checks its pinned SHA-256 and extracts it
// below the installer's managed directory, then checks that every command is in the plan's
// command directory there and records it. pluginruntime.Manager does the transfer and the
// extraction, the same as for managed runtimes: an extraction already in place that still
// holds the commands is used as it is, and a damaged one is replaced.
func (s *commandInstallSession) download(ctx context.Context, prepared preparedCommandInstall, progress func(pluginruntime.Progress)) (string, core.PluginStage, error) {
	plan, download := prepared.plan, prepared.plan.Download
	commandDirectory := func(installation pluginruntime.Installation) string {
		return filepath.Join(installation.Home, filepath.FromSlash(download.CommandDirectory))
	}
	timeout := prepared.timeout()
	run, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	manager := pluginruntime.Manager{Root: prepared.installDirectory, Downloader: s.app.plugins.RuntimeDownloader}
	installation, err := manager.Prepare(run, pluginruntime.Artifact{
		ID:          strings.Join(plan.Commands, ", "),
		Version:     download.Version,
		CacheKey:    download.CacheKey,
		URL:         download.URL,
		Mirrors:     download.Mirrors,
		SHA256:      download.SHA256,
		Archive:     download.Archive,
		StripPrefix: download.StripPrefix,
	}, func(_ context.Context, installation pluginruntime.Installation) error {
		directory := commandDirectory(installation)
		var absent []string
		for _, command := range plan.Commands {
			if _, err := pluginhost.CommandInDirectory(directory, command); err != nil {
				absent = append(absent, command)
			}
		}
		if len(absent) > 0 {
			// The extraction that lacks them is discarded, so the failure names where in the
			// archive they were looked for.
			return &pluginhost.CommandInstallError{Code: pluginhost.CommandInstallCommandsMissingCode, Commands: absent, Directory: archiveLocation(download)}
		}
		return nil
	}, progress)
	if err != nil {
		stage, err := downloadFailure(ctx, run, timeout, err)
		return "", stage, err
	}
	directory := commandDirectory(installation)
	// A record that cannot be written leaves the commands where later launches do not look,
	// which is the same outcome for them as commands missing from the directory.
	if err := s.app.plugins.Commands.Record(s.pluginID, pluginhost.CommandInstallation{Installer: s.installer.ID, Target: core.CommandInstallManaged, Directory: directory}); err != nil {
		return "", core.StageDecode, err
	}
	if err := removeOtherExtractions(prepared.installDirectory, download.CacheKey); err != nil {
		s.app.backgroundFailedIn(ctx, "plugin_command_download_cleanup", err)
	}
	return directory, "", nil
}

// removeOtherExtractions removes what earlier archives of an installer left in its managed
// directory root, every entry but keep's: the archive and extraction of a version the plugin
// pinned before an update, which no record names any more. An entry that cannot go, such as
// an adapter of the old version still running on Windows, stays for the next installation to
// remove; the installation that just finished does not depend on it.
func removeOtherExtractions(root, keep string) error {
	entries, err := os.ReadDir(root)
	if err != nil {
		return err
	}
	var failures []error
	for _, entry := range entries {
		if entry.Name() != keep {
			failures = append(failures, os.RemoveAll(filepath.Join(root, entry.Name())))
		}
	}
	return errors.Join(failures...)
}

// archiveLocation is a download's command directory inside its archive, after the archive's
// file name: tool-1.2.3-darwin-arm64.zip/extension/bin.
func archiveLocation(download *core.CommandInstallDownload) string {
	name := download.URL
	if parsed, err := url.Parse(download.URL); err == nil && path.Base(parsed.Path) != "/" && path.Base(parsed.Path) != "." {
		name = path.Base(parsed.Path)
	}
	return path.Join(name, download.StripPrefix, download.CommandDirectory)
}

// downloadFailure is the stage and the contract code of a download installation that failed
// with err. run is the installation's context, bounded by timeout within ctx, the user's.
func downloadFailure(ctx, run context.Context, timeout time.Duration, err error) (core.PluginStage, error) {
	var installErr *pluginhost.CommandInstallError
	switch {
	case ctx.Err() != nil:
		// The user cancelled, which is never recorded.
		return core.StageExit, ctx.Err()
	case run.Err() != nil:
		// A stalled transfer also ends with a deadline, so the installation's own context
		// decides whether its time ran out.
		return core.StageTimeout, &pluginhost.CommandInstallError{Code: pluginhost.CommandInstallTimedOutCode, Timeout: timeout}
	case errors.As(err, &installErr):
		return core.StageDecode, installErr
	case errors.Is(err, marketplace.ErrArchiveChecksum):
		return core.StageResolve, &pluginhost.CommandInstallError{Code: pluginhost.CommandInstallChecksumMismatchCode, Err: err}
	case errors.Is(err, pluginruntime.ErrDownload):
		return core.StageResolve, &pluginhost.CommandInstallError{Code: pluginhost.CommandInstallDownloadFailedCode, Err: err}
	case errors.Is(err, pluginruntime.ErrArchive):
		return core.StageDecode, &pluginhost.CommandInstallError{Code: pluginhost.CommandInstallArchiveInvalidCode, Err: err}
	}
	return core.StageDecode, err
}

// commandInstallSession is one installer with its tool resolved, for an offer or an
// installation. A download installer has no tool, so nothing is resolved for it.
type commandInstallSession struct {
	app       *App
	pluginID  string
	manifest  json.RawMessage
	installer core.CommandInstaller
	// directory is an empty directory of its own the tool runs in, so no project's files change
	// what it installs; close removes it. Empty for a download installer.
	directory string
	selection core.ToolchainSelection
}

// open finds the installer in the plugin's manifest and resolves its tool. The tool resolves
// in the open project, so a version the project pins is the one that installs; without a
// project it resolves from the user's settings alone. stage is where a failure happened.
func (s settingsCommandInstalls) open(ctx context.Context, pluginID, installerID string) (*commandInstallSession, core.PluginStage, error) {
	manifest, err := s.manifest(ctx, pluginID)
	if err != nil {
		return nil, core.StagePlan, err
	}
	requirements, err := s.app.kernel.CommandInstallerRequirements(ctx, manifest, archivePlatform())
	if err != nil {
		return nil, core.StagePlan, err
	}
	index := slices.IndexFunc(requirements.Installers, func(installer core.CommandInstaller) bool { return installer.ID == installerID })
	if index < 0 {
		return nil, core.StagePlan, fmt.Errorf("plugin %s declares no installer %s", pluginID, installerID)
	}
	installer := requirements.Installers[index]
	if installer.Download != nil || installer.Tool == nil {
		return &commandInstallSession{app: s.app, pluginID: pluginID, manifest: manifest, installer: installer}, "", nil
	}
	directory, err := os.MkdirTemp("", "lithe-command-install-")
	if err != nil {
		return nil, core.StagePlan, err
	}
	session := &commandInstallSession{app: s.app, pluginID: pluginID, manifest: manifest, installer: installer, directory: directory}
	root := directory
	if current := s.app.toolchainRoot.Load(); current != nil {
		root = *current
	}
	minimumVersion := ""
	if session.installer.MinimumVersion != nil {
		minimumVersion = *session.installer.MinimumVersion
	}
	session.selection, err = s.app.resolveToolchainSelection(ctx, root, ".", *session.installer.Tool, minimumVersion)
	if err != nil {
		session.close()
		return nil, core.StageResolve, err
	}
	return session, "", nil
}

func (s *commandInstallSession) close() {
	if s != nil && s.directory != "" {
		os.RemoveAll(s.directory)
	}
}

// preparedCommandInstall is one target of an installer, expanded.
type preparedCommandInstall struct {
	plan core.CommandInstallPlan
	// installDirectory is the directory a managed installation writes into; empty for
	// toolDefault.
	installDirectory string
	// directory is where the commands land; empty when no directory probe named one. For a
	// download it is installDirectory, below which the archive's extraction gets a directory
	// of its own.
	directory string
}

func (p preparedCommandInstall) timeout() time.Duration {
	return time.Duration(p.plan.TimeoutMilliseconds) * time.Millisecond
}

// prepare has Core expand target: a managed one into the plugin's install directory, a
// toolDefault one with the directory its probes name. A download is planned for this host's
// platform without a directory; the host extracts it below the install directory itself.
func (s *commandInstallSession) prepare(ctx context.Context, target string) (preparedCommandInstall, error) {
	kernel := s.app.kernel
	switch target {
	case core.CommandInstallManaged:
		installDirectory, err := s.app.plugins.Commands.InstallDirectory(s.pluginID, s.installer.ID)
		if err != nil {
			return preparedCommandInstall{}, err
		}
		if s.installer.Download != nil {
			plan, err := kernel.PlanCommandInstaller(ctx, s.manifest, s.installer.ID, target, "", archivePlatform())
			if err != nil {
				return preparedCommandInstall{}, err
			}
			if plan.Download == nil {
				return preparedCommandInstall{}, fmt.Errorf("installer %s was planned without its download", s.installer.ID)
			}
			return preparedCommandInstall{plan: plan, installDirectory: installDirectory, directory: installDirectory}, nil
		}
		plan, err := kernel.PlanCommandInstaller(ctx, s.manifest, s.installer.ID, target, installDirectory, archivePlatform())
		if err != nil {
			return preparedCommandInstall{}, err
		}
		if plan.CommandDirectory == nil {
			return preparedCommandInstall{}, fmt.Errorf("installer %s was planned without its command directory", s.installer.ID)
		}
		return preparedCommandInstall{plan: plan, installDirectory: installDirectory, directory: *plan.CommandDirectory}, nil
	case core.CommandInstallToolDefault:
		plan, err := kernel.PlanCommandInstaller(ctx, s.manifest, s.installer.ID, target, "", archivePlatform())
		if err != nil {
			return preparedCommandInstall{}, err
		}
		outputs := make([]*string, len(plan.DirectoryProbes))
		for i, probe := range plan.DirectoryProbes {
			if output, ok := s.probe(ctx, probe.Arguments); ok {
				outputs[i] = &output
			}
		}
		directory, _, err := kernel.CommandInstallerDefaultDirectory(ctx, s.manifest, s.installer.ID, outputs)
		if err != nil {
			return preparedCommandInstall{}, err
		}
		return preparedCommandInstall{plan: plan, directory: directory}, nil
	}
	return preparedCommandInstall{}, fmt.Errorf("unknown command install target %q", target)
}

// probe runs the tool with one probe's arguments and returns its standard output. ok is
// false when the probe could not run, failed, ran too long or printed too much.
func (s *commandInstallSession) probe(ctx context.Context, arguments []string) (string, bool) {
	ctx, cancel := context.WithTimeout(ctx, commandProbeTimeout)
	defer cancel()
	var output strings.Builder
	overflow := false
	process, err := buildprocess.Start(ctx, buildprocess.Spec{
		Executable:       s.selection.Executable,
		Arguments:        arguments,
		WorkingDirectory: s.directory,
		Environment:      applyToolchainSelection(nil, s.selection),
	}, func(stream buildprocess.Stream, text string) {
		// Only the stdout reader writes here, and Wait returns after it ends.
		if stream != buildprocess.Stdout || overflow {
			return
		}
		if output.Len()+len(text) > maxCommandProbeOutput {
			overflow = true
			return
		}
		output.WriteString(text)
	})
	if err != nil {
		return "", false
	}
	if process.Wait() != nil || ctx.Err() != nil || overflow {
		return "", false
	}
	return output.String(), true
}

// commandMissingMessage tells the user, in language, which commands a launch found none of and
// where to install them; ok is false for any other error.
func commandMissingMessage(language i18n.Language, err error) (string, bool) {
	var missing *pluginhost.CommandMissingError
	if !errors.As(err, &missing) {
		return "", false
	}
	return i18n.SharedFormat(language, "desktop.plugins.commandMissingHelp", map[string]string{"commands": strings.Join(missing.Commands, " | ")}), true
}

// launchFailureText is the message of a plugin launch or provider request that failed: the
// missing commands when it found none, why safe mode holds the process back when Core refused
// it for want of trust, the provider's own message when the provider answered with an error,
// the error itself otherwise.
func (a *App) launchFailureText(err error) string {
	if message, ok := commandMissingMessage(a.language(), err); ok {
		return message
	}
	if core.IsLaunchUntrustedWorkspace(err) {
		return i18n.Shared(a.language(), "desktop.trust.launchSafeMode")
	}
	var provider *buildprovider.ProviderError
	if errors.As(err, &provider) {
		return provider.UserMessage()
	}
	return err.Error()
}

// commandOutputLines turns an installation's output chunks into lines for the install dialog.
// Each stream keeps its own unfinished line, so the two never mix inside one line.
type commandOutputLines struct {
	send    func(string)
	mu      sync.Mutex
	pending map[buildprocess.Stream]*strings.Builder
}

func (o *commandOutputLines) write(stream buildprocess.Stream, text string) {
	if o.send == nil {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.pending == nil {
		o.pending = make(map[buildprocess.Stream]*strings.Builder, 2)
	}
	line := o.pending[stream]
	if line == nil {
		line = &strings.Builder{}
		o.pending[stream] = line
	}
	for text != "" {
		end := strings.IndexByte(text, '\n')
		part := text
		if end >= 0 {
			part = text[:end]
		}
		if room := maxCommandOutputLine - line.Len(); len(part) > room {
			part = part[:max(room, 0)]
		}
		line.WriteString(part)
		if end < 0 {
			return
		}
		o.send(commandOutputText(line.String()))
		line.Reset()
		text = text[end+1:]
	}
}

// flush hands on the unfinished line of each stream once the tool has ended.
func (o *commandOutputLines) flush() {
	if o.send == nil {
		return
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	for _, stream := range []buildprocess.Stream{buildprocess.Stdout, buildprocess.Stderr} {
		if line := o.pending[stream]; line != nil && line.Len() > 0 {
			o.send(commandOutputText(line.String()))
			line.Reset()
		}
	}
}

// commandOutputText is one line as the dialog shows it: without the carriage return of a CRLF
// line ending, and with the bytes of a character a bounded line cut through dropped.
func commandOutputText(line string) string {
	return strings.ToValidUTF8(strings.TrimSuffix(line, "\r"), "")
}
