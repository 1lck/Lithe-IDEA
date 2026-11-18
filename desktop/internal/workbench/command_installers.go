package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprovider"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginmanager"
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
// Core expands every installer and names its directories; the host resolves the tool, runs
// it, checks that the commands landed and records where.
type settingsCommandInstalls struct{ app *App }

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
	requirements, err := s.app.kernel.CommandInstallerRequirements(ctx, manifest)
	if err != nil {
		return nil, err
	}
	installers := make(map[string]core.CommandInstaller, len(requirements.Installers))
	for _, installer := range requirements.Installers {
		installers[installer.ID] = installer
	}
	var missing []settingswindow.MissingCommand
	var tools map[string]string
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
			if tools == nil {
				tools = s.toolNames(ctx)
			}
			entry.Installer, entry.Tool = installer.ID, toolName(tools, installer.Tool)
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
	manifests, _ := s.app.toolchainManifests(ctx)
	if len(manifests) == 0 {
		return nil
	}
	registry, err := s.app.kernel.ToolchainRegistryOf(ctx, manifests)
	if err != nil {
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
// target's directory probes to find where it would install.
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
	offer := settingswindow.CommandInstallOffer{
		Installer:     installerID,
		Commands:      session.installer.Commands,
		Tool:          toolName(s.toolNames(ctx), session.installer.Tool),
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
// plugin's later launches find them. The attempt is recorded on the plugin's host channel; a
// cancelled one is not.
func (s settingsCommandInstalls) Install(ctx context.Context, pluginID, installerID, target string, output func(string)) (_ string, err error) {
	// The dialog's Install button is the action; the attempt and the installer's tool run under
	// its operation.
	ctx = s.app.performedIn(ctx, "plugin.commandInstaller.install", surfaceButton)
	defer func() { (settingsToolchains{app: s.app}).recordFailure(ctx, "plugin_command_install", err) }()
	attempt := core.StartPluginAttempt(pluginID, core.OperationCommandInstallerInstall, core.OriginOf(ctx).Operation)
	defer attempt.Abandon()
	directory, stage, err := s.install(ctx, pluginID, installerID, target, output)
	if s.app.plugins != nil {
		s.app.plugins.EndAttempt(ctx, attempt, stage, err)
	}
	return directory, err
}

func (s settingsCommandInstalls) install(ctx context.Context, pluginID, installerID, target string, output func(string)) (string, core.PluginStage, error) {
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

// commandInstallSession is one installer with its tool resolved, for an offer or an
// installation.
type commandInstallSession struct {
	app       *App
	pluginID  string
	manifest  json.RawMessage
	installer core.CommandInstaller
	// directory is an empty directory of its own the tool runs in, so no project's files change
	// what it installs; close removes it.
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
	requirements, err := s.app.kernel.CommandInstallerRequirements(ctx, manifest)
	if err != nil {
		return nil, core.StagePlan, err
	}
	index := slices.IndexFunc(requirements.Installers, func(installer core.CommandInstaller) bool { return installer.ID == installerID })
	if index < 0 {
		return nil, core.StagePlan, fmt.Errorf("plugin %s declares no installer %s", pluginID, installerID)
	}
	directory, err := os.MkdirTemp("", "lithe-command-install-")
	if err != nil {
		return nil, core.StagePlan, err
	}
	session := &commandInstallSession{app: s.app, pluginID: pluginID, manifest: manifest, installer: requirements.Installers[index], directory: directory}
	root := directory
	if current := s.app.toolchainRoot.Load(); current != nil {
		root = *current
	}
	minimumVersion := ""
	if session.installer.MinimumVersion != nil {
		minimumVersion = *session.installer.MinimumVersion
	}
	session.selection, err = s.app.resolveToolchainSelection(ctx, root, ".", session.installer.Tool, minimumVersion)
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
	// directory is where the commands land; empty when no directory probe named one.
	directory string
}

func (p preparedCommandInstall) timeout() time.Duration {
	return time.Duration(p.plan.TimeoutMilliseconds) * time.Millisecond
}

// prepare has Core expand target: a managed one into the plugin's install directory, a
// toolDefault one with the directory its probes name.
func (s *commandInstallSession) prepare(ctx context.Context, target string) (preparedCommandInstall, error) {
	kernel := s.app.kernel
	switch target {
	case core.CommandInstallManaged:
		installDirectory, err := s.app.plugins.Commands.InstallDirectory(s.pluginID, s.installer.ID)
		if err != nil {
			return preparedCommandInstall{}, err
		}
		plan, err := kernel.PlanCommandInstaller(ctx, s.manifest, s.installer.ID, target, installDirectory)
		if err != nil {
			return preparedCommandInstall{}, err
		}
		return preparedCommandInstall{plan: plan, installDirectory: installDirectory, directory: *plan.CommandDirectory}, nil
	case core.CommandInstallToolDefault:
		plan, err := kernel.PlanCommandInstaller(ctx, s.manifest, s.installer.ID, target, "")
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
// missing commands when it found none, the provider's own message when the provider answered
// with an error, the error itself otherwise.
func (a *App) launchFailureText(err error) string {
	if message, ok := commandMissingMessage(a.language(), err); ok {
		return message
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
