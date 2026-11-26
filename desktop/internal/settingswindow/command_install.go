package settingswindow

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginhost"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginruntime"
	"github.com/1lck/Lithe-IDEA/desktop/internal/toolchain"
	"github.com/vivaui/viva/ui"
)

// commandCheckTimeout bounds one check of a plugin's commands: a few Core calls and PATH
// lookups.
const commandCheckTimeout = 15 * time.Second

// commandOfferTimeout bounds preparing the install dialog: resolving the tool and running
// its directory probes.
const commandOfferTimeout = 30 * time.Second

// commandOutputLines is how many of the last lines an installation printed the dialog keeps.
const commandOutputLines = 200

// commandOutputHeight is the height of the dialog's output box.
const commandOutputHeight = 160

// commandCheckOperation and commandOfferOperation name, in the log, a check or an install
// dialog that could not be prepared. The installation itself is a plugin operation the
// workbench records.
const (
	commandCheckOperation = "plugin_command_check"
	commandOfferOperation = "plugin_command_offer"
)

// commandCheckKey names one check: the plugin and the generation it was asked in.
type commandCheckKey struct {
	plugin     string
	generation int
}

// commandCheck is what one check found.
type commandCheck struct {
	key     commandCheckKey
	missing []MissingCommand
}

type commandOfferRequest struct{ pluginID, installerID string }

type commandInstallRequest struct {
	pluginID, installerID, target string
	output                        *commandOutput
}

// commandInstalls is the Installed tab's view of the commands plugins need: which of the shown
// plugin's commands are missing, and the dialog that installs them. Everything runs on the
// window thread but the effects' run functions and commandOutput.
type commandInstalls struct {
	source CommandInstaller
	report func(operation string, err error)
	wake   func()

	check *ui.EffectState[commandCheck, commandCheckKey]
	// key is the check to run; a zero one means none. generation grows when the shown plugin
	// changes, an installation finishes or the plugin registry changes, so the next paint of
	// the plugin checks again.
	key        commandCheckKey
	generation int
	shown      string
	results    map[string]commandCheck

	offer   *ui.EffectState[CommandInstallOffer, *commandOfferRequest]
	install *ui.EffectState[string, *commandInstallRequest]
	dialog  *commandInstallDialog
}

// commandInstallDialog is one install dialog: the offer it shows, the target the user picks,
// then the installation's output and outcome.
type commandInstallDialog struct {
	pluginID, pluginName string
	missing              MissingCommand
	open                 bool

	offerRequest *commandOfferRequest
	offer        *CommandInstallOffer
	offerErr     error
	target       string

	installRequest *commandInstallRequest
	output         *commandOutput
	directory      string
	installErr     error
}

func newCommandInstalls(source CommandInstaller, report func(string, error), wake func()) *commandInstalls {
	s := &commandInstalls{source: source, report: report, wake: wake, results: make(map[string]commandCheck)}
	if source == nil {
		return s
	}
	s.check = ui.NewEffectKeyed[commandCheck, commandCheckKey](func(ctx context.Context, key commandCheckKey) (commandCheck, error) {
		ctx, cancel := context.WithTimeout(ctx, commandCheckTimeout)
		defer cancel()
		missing, err := source.Missing(ctx, key.plugin)
		return commandCheck{key: key, missing: missing}, err
	})
	s.offer = ui.NewEffectKeyed[CommandInstallOffer, *commandOfferRequest](func(ctx context.Context, request *commandOfferRequest) (CommandInstallOffer, error) {
		ctx, cancel := context.WithTimeout(ctx, commandOfferTimeout)
		defer cancel()
		return source.Offer(ctx, request.pluginID, request.installerID)
	})
	// The installer bounds its own run by the plan's timeout.
	s.install = ui.NewEffectKeyed[string, *commandInstallRequest](func(ctx context.Context, request *commandInstallRequest) (string, error) {
		return source.Install(ctx, request.pluginID, request.installerID, request.target, request.output.add, request.output.setProgress)
	})
	return s
}

// want returns what the last check of pluginID found, and asks for a new check when the
// plugin was not the one shown before or something changed since that check.
func (s *commandInstalls) want(pluginID string) []MissingCommand {
	if s == nil || s.check == nil {
		return nil
	}
	if pluginID != s.shown {
		s.shown = pluginID
		s.generation++
	}
	result, ok := s.results[pluginID]
	if !ok || result.key.generation != s.generation {
		s.key = commandCheckKey{plugin: pluginID, generation: s.generation}
	}
	return result.missing
}

// invalidate checks the shown plugin again on its next paint.
func (s *commandInstalls) invalidate() {
	if s != nil {
		s.generation++
	}
}

// take keeps the results the effects finished with.
func (s *commandInstalls) take() {
	if s == nil || s.check == nil {
		return
	}
	if result, err, ok := s.check.Take(); ok {
		if err != nil {
			s.report(commandCheckOperation, err)
			result.missing = nil
		}
		s.results[result.key.plugin] = result
		if s.key == result.key {
			s.key = commandCheckKey{}
		}
	}
	dialog := s.dialog
	if offer, err, ok := s.offer.Take(); ok && dialog != nil && dialog.offerRequest != nil {
		dialog.offerRequest = nil
		if err != nil {
			dialog.offerErr = err
			s.report(commandOfferOperation, err)
		} else {
			dialog.offer = &offer
			dialog.target = ""
			for _, target := range offer.Targets {
				if target.Directory != "" {
					dialog.target = target.Target
					break
				}
			}
		}
	}
	if directory, err, ok := s.install.Take(); ok && dialog != nil && dialog.installRequest != nil {
		dialog.installRequest = nil
		dialog.directory, dialog.installErr = directory, err
		// What was installed, or half installed, changes what the plugin is missing.
		s.invalidate()
	}
}

// declare declares the work the tab asked for.
func (s *commandInstalls) declare(c ui.C) {
	if s == nil || s.check == nil {
		return
	}
	if s.key.plugin != "" {
		ui.Effect(c, s.check, s.key)
	}
	if dialog := s.dialog; dialog != nil {
		if dialog.offerRequest != nil {
			ui.Effect(c, s.offer, dialog.offerRequest)
		}
		if dialog.installRequest != nil {
			ui.Effect(c, s.install, dialog.installRequest)
		}
	}
}

// start opens the install dialog for one missing launch of a plugin.
func (s *commandInstalls) start(pluginID, pluginName string, missing MissingCommand) {
	if s.check == nil || missing.Installer == "" {
		return
	}
	s.dialog = &commandInstallDialog{pluginID: pluginID, pluginName: pluginName, missing: missing, open: true}
	s.loadOffer()
}

func (s *commandInstalls) loadOffer() {
	dialog := s.dialog
	dialog.offer, dialog.offerErr = nil, nil
	dialog.offerRequest = &commandOfferRequest{pluginID: dialog.pluginID, installerID: dialog.missing.Installer}
}

func (s *commandInstalls) runInstall() {
	dialog := s.dialog
	if dialog == nil || dialog.offer == nil || dialog.installRequest != nil {
		return
	}
	dialog.directory, dialog.installErr = "", nil
	dialog.output = &commandOutput{wake: s.wake}
	dialog.installRequest = &commandInstallRequest{
		pluginID: dialog.pluginID, installerID: dialog.offer.Installer, target: dialog.target, output: dialog.output,
	}
}

// close drops the dialog. An installation still running stops with it: its effect is no
// longer declared, which cancels it and so stops the tool.
func (s *commandInstalls) close() {
	s.dialog = nil
}

// commandOutput keeps the last lines an installation printed, or the last phase a download
// reported. The installation's goroutine adds them; the window thread reads them.
type commandOutput struct {
	wake func()

	mu       sync.Mutex
	lines    []string
	progress *pluginruntime.Progress
}

func (o *commandOutput) setProgress(progress pluginruntime.Progress) {
	o.mu.Lock()
	o.progress = &progress
	o.mu.Unlock()
	if o.wake != nil {
		o.wake()
	}
}

// lastProgress is the last phase a download reported; ok is false before the first and for
// a tool installation.
func (o *commandOutput) lastProgress() (pluginruntime.Progress, bool) {
	if o == nil {
		return pluginruntime.Progress{}, false
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.progress == nil {
		return pluginruntime.Progress{}, false
	}
	return *o.progress, true
}

func (o *commandOutput) add(line string) {
	o.mu.Lock()
	if len(o.lines) == commandOutputLines {
		o.lines = append(o.lines[:0], o.lines[1:]...)
	}
	o.lines = append(o.lines, line)
	o.mu.Unlock()
	if o.wake != nil {
		o.wake()
	}
}

func (o *commandOutput) text() string {
	if o == nil {
		return ""
	}
	o.mu.Lock()
	defer o.mu.Unlock()
	return strings.Join(o.lines, "\n")
}

// missingFor is the missing launch of capability, if any.
func missingFor(missing []MissingCommand, capability PluginCapability) (MissingCommand, bool) {
	for _, entry := range missing {
		if entry.Kind != "" && entry.Kind == capability.Kind && entry.ID == capability.ID {
			return entry, true
		}
	}
	return MissingCommand{}, false
}

// unmatchedMissing lists the missing launches no card shows, such as the backend's.
func unmatchedMissing(missing []MissingCommand, capabilities []PluginCapability) []MissingCommand {
	var unmatched []MissingCommand
	for _, entry := range missing {
		shown := false
		for _, capability := range capabilities {
			if _, ok := missingFor([]MissingCommand{entry}, capability); ok {
				shown = true
				break
			}
		}
		if !shown {
			unmatched = append(unmatched, entry)
		}
	}
	return unmatched
}

func commandList(commands []string) string {
	return strings.Join(commands, " | ")
}

// commandMissingStatus is a card's status line for a launch whose commands are missing: the
// words, then an install button, or a note that the user has to install them.
func (w *window) commandMissingStatus(c ui.C, language i18n.Language, fact PluginFacts, missing MissingCommand) {
	ui.Text(c, i18n.SharedFormat(language, "desktop.plugins.commandMissing", map[string]string{"commands": commandList(missing.Commands)})).
		FontSize(11).Color(w.pal.warning).Shrink(1).MinWidth(0).Ellipsis()
	if missing.Installer == "" {
		w.infoButton(c, i18n.Shared(language, "desktop.plugins.commandMissingManual"))
		return
	}
	if ui.Button(c, i18n.Shared(language, "desktop.marketplace.install")).XSmall().Clicked() {
		pluginID, name := fact.ID, fact.Name
		c.After(func() { w.commands.start(pluginID, name, missing) })
	}
}

// commandMissingBanner shows, above the cards, the missing launches no card shows.
func (w *window) commandMissingBanner(c ui.C, language i18n.Language, fact PluginFacts, missing []MissingCommand) {
	for index, entry := range missing {
		k := c.Key("command-missing:" + strconv.Itoa(index))
		ui.Row(k).FillWidth().Gap(8).Pad(10).Radius(8).Items(ui.Center).Stroke(1, w.pal.line).Background(w.pal.card).Children(func() {
			ui.Wrap(c, i18n.SharedFormat(language, "desktop.plugins.commandMissingBanner", map[string]string{"commands": commandList(entry.Commands)})).
				FontSize(12).Color(w.pal.warning).Grow(1).Shrink(1).MinWidth(0)
			if entry.Installer == "" {
				w.infoButton(k, i18n.Shared(language, "desktop.plugins.commandMissingManual"))
				return
			}
			if ui.Button(k, i18n.Shared(language, "desktop.marketplace.install")).XSmall().Clicked() {
				pluginID, name, chosen := fact.ID, fact.Name, entry
				k.After(func() { w.commands.start(pluginID, name, chosen) })
			}
		})
	}
}

// commandInstallModal is the install dialog, when one is open.
func (w *window) commandInstallModal(c ui.C) {
	s := w.commands
	if s == nil || s.dialog == nil {
		return
	}
	dialog := s.dialog
	language := w.marketLanguage()
	installing := dialog.installRequest != nil
	installed := dialog.output != nil && !installing && dialog.installErr == nil
	installFailed := dialog.output != nil && !installing && dialog.installErr != nil
	var cancelled, confirmed, retried bool
	title := i18n.SharedFormat(language, "desktop.plugins.commandInstallTitle", map[string]string{"commands": commandList(dialog.missing.Commands)})
	closed := ui.Modal(c, &dialog.open, title, ui.ModalSpec{Width: 620, Description: dialog.pluginName}, func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			switch {
			case installing:
				w.commandInstallProgress(c, language, dialog.output)
				w.commandInstallOutput(c, language, dialog.output)
			case installed:
				ui.Wrap(c, i18n.SharedFormat(language, "desktop.plugins.commandInstalled", map[string]string{"directory": dialog.directory})).Color(w.pal.success)
				w.commandInstallOutput(c, language, dialog.output)
			case installFailed:
				ui.Wrap(c, commandInstallFailureText(language, dialog.missing.Tool, dialog.installErr)).Color(w.pal.danger)
				w.commandInstallOutput(c, language, dialog.output)
			case dialog.offerErr != nil:
				ui.Wrap(c, commandInstallFailureText(language, dialog.missing.Tool, dialog.offerErr)).Color(w.pal.danger)
			case dialog.offer == nil:
				ui.Text(c, i18n.Shared(language, "native.loading"))
				ui.Progress(c, 0).Indeterminate().FillWidth()
			default:
				w.commandInstallOffer(c, language, dialog)
			}
		})
	}, func() {
		switch {
		case installing:
			cancelled = ui.Button(c, i18n.Shared(language, "ui.cancel")).Outline().Clicked()
		case installed:
			cancelled = ui.Button(c, i18n.Shared(language, "ui.done")).AutoFocus().Clicked()
		case installFailed, dialog.offerErr != nil:
			cancelled = ui.Button(c, i18n.Shared(language, "ui.close")).Outline().Clicked()
			retried = ui.Button(c, i18n.Shared(language, "ui.retry")).Clicked()
		case dialog.offer == nil:
			cancelled = ui.Button(c, i18n.Shared(language, "ui.cancel")).Outline().Clicked()
		default:
			cancelled = ui.Button(c, i18n.Shared(language, "ui.cancel")).Outline().Clicked()
			confirmed = ui.Button(c, i18n.Shared(language, "desktop.marketplace.install")).Disabled(!dialog.targetUsable()).AutoFocus().Clicked()
		}
	})
	switch {
	case retried:
		c.After(func() {
			if s.dialog != dialog {
				return
			}
			if dialog.offerErr != nil {
				s.loadOffer()
			} else {
				s.runInstall()
			}
		})
	case confirmed:
		c.After(func() {
			if s.dialog == dialog && dialog.targetUsable() {
				s.runInstall()
			}
		})
	case closed || cancelled:
		c.After(func() {
			if s.dialog == dialog {
				s.close()
			}
		})
	}
}

// targetUsable says the picked target names a directory the host can find the commands in.
func (d *commandInstallDialog) targetUsable() bool {
	if d.offer == nil {
		return false
	}
	for _, target := range d.offer.Targets {
		if target.Target == d.target {
			return target.Directory != ""
		}
	}
	return false
}

// commandInstallProgress is the running installation's status: a download's phase, with
// how much of the archive arrived when its size is known, or that a tool is installing.
func (w *window) commandInstallProgress(c ui.C, language i18n.Language, output *commandOutput) {
	progress, ok := output.lastProgress()
	if !ok {
		ui.Text(c, i18n.Shared(language, "settings.general.installing"))
		ui.Progress(c, 0).Indeterminate().FillWidth()
		return
	}
	ui.Wrap(c, RuntimeProgressText(language, progress))
	if progress.Phase == "downloading" && progress.Total > 0 {
		ui.Progress(c, float32(progress.Received)/float32(progress.Total)).FillWidth()
		return
	}
	ui.Progress(c, 0).Indeterminate().FillWidth()
}

// commandInstallOffer is the confirmation: what runs, whether it downloads, and where the
// commands may go. A download names the archive's addresses and digest instead of a tool and
// its command line.
func (w *window) commandInstallOffer(c ui.C, language i18n.Language, dialog *commandInstallDialog) {
	offer := dialog.offer
	if download := offer.Download; download != nil {
		ui.Wrap(c, i18n.SharedFormat(language, "desktop.plugins.commandInstallDownloadPrompt", map[string]string{
			"commands": commandList(offer.Commands), "version": download.Version,
		}))
		ui.Wrap(c, i18n.Shared(language, "desktop.plugins.commandInstallDownloadNetwork")).FontSize(12).Color(w.pal.warning)
		ui.Text(c, i18n.Shared(language, "desktop.plugins.commandInstallSource")).FontSize(13).Bold().PadTop(4)
		// Labels are in the text font, so a translated label keeps its own spacing; the address
		// and the digest are monospaced.
		labelled := func(k ui.C, label, value string) {
			ui.Row(k).FillWidth().Gap(6).Children(func() {
				ui.Text(c, label).FontSize(11).Color(w.pal.muted).Shrink(0)
				ui.Wrap(c, value).Mono().FontSize(11).Color(w.pal.muted).Grow(1).Shrink(1).MinWidth(0)
			})
		}
		ui.Column(c).FillWidth().Gap(2).Pad(8).Radius(6).Background(w.pal.card).Stroke(1, w.pal.line).Children(func() {
			ui.Wrap(c, download.URL).Mono().FontSize(11).Color(w.pal.text)
			for index, mirror := range download.Mirrors {
				labelled(c.KeyInt(index), i18n.Shared(language, "desktop.plugins.commandInstallMirror"), mirror)
			}
			labelled(c.KeyInt(len(download.Mirrors)), i18n.Shared(language, "desktop.plugins.commandInstallDigest"), download.SHA256)
		})
	} else {
		ui.Wrap(c, i18n.SharedFormat(language, "desktop.plugins.commandInstallPrompt", map[string]string{
			"tool": offer.Tool, "commands": commandList(offer.Commands),
		}))
		if offer.MayUseNetwork {
			ui.Wrap(c, i18n.Shared(language, "desktop.plugins.commandInstallNetwork")).FontSize(12).Color(w.pal.warning)
		}
	}
	ui.Text(c, i18n.Shared(language, "desktop.plugins.commandInstallLocation")).FontSize(13).Bold().PadTop(4)
	var chosen *CommandInstallTarget
	for index := range offer.Targets {
		target := &offer.Targets[index]
		k := c.KeyInt(index)
		label, help := commandTargetWords(language, offer.Tool, target.Target)
		if target.Directory == "" {
			help = i18n.SharedFormat(language, "desktop.plugins.commandInstallNoDirectory", map[string]string{"tool": offer.Tool})
		}
		ui.Column(k).FillWidth().Gap(2).Children(func() {
			w.radio(k, &dialog.target, target.Target, label, target.Directory == "")
			ui.Column(k).FillWidth().Gap(2).PadLeft(radioSize + 8).Children(func() {
				ui.Wrap(c, help).FontSize(11).Color(w.pal.muted)
				if target.Directory != "" {
					ui.Wrap(c, target.Directory).Mono().FontSize(11).Color(w.pal.subtle)
				}
			})
		})
		if target.Target == dialog.target {
			chosen = target
		}
	}
	if chosen == nil || chosen.CommandLine == "" {
		return
	}
	ui.Text(c, i18n.Shared(language, "desktop.plugins.commandInstallCommand")).FontSize(13).Bold().PadTop(4)
	ui.Column(c).FillWidth().Gap(2).Pad(8).Radius(6).Background(w.pal.card).Stroke(1, w.pal.line).Children(func() {
		for _, variable := range chosen.Environment {
			ui.Wrap(c, variable).Mono().FontSize(11).Color(w.pal.muted)
		}
		ui.Wrap(c, chosen.CommandLine).Mono().FontSize(11).Color(w.pal.text)
	})
}

// commandTargetWords is a target's radio label and the line under it.
func commandTargetWords(language i18n.Language, tool, target string) (string, string) {
	if target == core.CommandInstallToolDefault {
		return i18n.SharedFormat(language, "desktop.plugins.commandInstallToolDefault", map[string]string{"tool": tool}),
			i18n.Shared(language, "desktop.plugins.commandInstallToolDefaultHelp")
	}
	return i18n.Shared(language, "desktop.plugins.commandInstallManaged"), i18n.Shared(language, "desktop.plugins.commandInstallManagedHelp")
}

// commandInstallOutput shows what the installation printed so far.
func (w *window) commandInstallOutput(c ui.C, language i18n.Language, output *commandOutput) {
	text := output.text()
	if text == "" {
		return
	}
	ui.Text(c, i18n.Shared(language, "desktop.plugins.commandInstallOutput")).FontSize(13).Bold().PadTop(4)
	ui.Scroll(c.Part("command-output")).Scrollbars().FillWidth().MaxHeight(commandOutputHeight).Pad(8).Radius(6).Background(w.pal.card).Stroke(1, w.pal.line).Children(func() {
		ui.Wrap(c, text).Mono().FontSize(11).Color(w.pal.text).FillWidth()
	})
}

// commandInstallFailureText is why an installation, or preparing it, failed, in the user's
// language. tool is the display name of the installer's tool.
func commandInstallFailureText(language i18n.Language, tool string, err error) string {
	var installErr *pluginhost.CommandInstallError
	var unavailable *toolchain.UnavailableError
	switch {
	case errors.As(err, &installErr):
		switch installErr.Code {
		case pluginhost.CommandInstallTimedOutCode:
			return i18n.SharedFormat(language, "desktop.plugins.commandInstallTimedOut", map[string]string{
				"seconds": strconv.Itoa(int(installErr.Timeout / time.Second)),
			})
		case pluginhost.CommandInstallCommandsMissingCode:
			return i18n.SharedFormat(language, "desktop.plugins.commandInstallCommandsMissing", map[string]string{
				"commands": commandList(installErr.Commands), "directory": installErr.Directory,
			})
		case pluginhost.CommandInstallFailedCode:
			if installErr.ExitCode < 0 {
				return i18n.Shared(language, "desktop.plugins.commandInstallStopped")
			}
			return i18n.SharedFormat(language, "desktop.plugins.commandInstallFailed", map[string]string{"code": strconv.Itoa(installErr.ExitCode)})
		case pluginhost.CommandInstallDownloadFailedCode:
			return i18n.SharedFormat(language, "desktop.plugins.commandInstallDownloadFailed", map[string]string{"reason": causeText(installErr)})
		case pluginhost.CommandInstallChecksumMismatchCode:
			return i18n.Shared(language, "desktop.plugins.commandInstallChecksumMismatch")
		case pluginhost.CommandInstallArchiveInvalidCode:
			return i18n.SharedFormat(language, "desktop.plugins.commandInstallArchiveInvalid", map[string]string{"reason": causeText(installErr)})
		}
	case errors.As(err, &unavailable):
		if tool == "" {
			tool = unavailable.Tool
		}
		return i18n.SharedFormat(language, "desktop.plugins.commandInstallToolMissing", map[string]string{"tool": tool})
	}
	return i18n.SharedFormat(language, "desktop.plugins.commandInstallError", map[string]string{"reason": err.Error()})
}

// causeText is the untranslated error a download failure wraps, or its code without one.
func causeText(err *pluginhost.CommandInstallError) string {
	if err.Err == nil {
		return err.Code
	}
	return err.Err.Error()
}
