package settingswindow

import (
	"context"
	"errors"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// LocalHistorySettings are the user's stored local history settings. IgnorePatterns and
// IgnoreRegexes are Core's ignore rules as the user wrote them, without blank lines: a
// "!**/name/" pattern turns one of Core's built-in folders off. LimitMegabytes is the space one
// project's history may take, in MiB; zero keeps Core's default, and Core keeps any other value
// within its own bounds.
type LocalHistorySettings struct {
	IgnorePatterns []string `json:"ignorePatterns,omitempty"`
	IgnoreRegexes  []string `json:"ignoreRegexes,omitempty"`
	LimitMegabytes int      `json:"limitMegabytes,omitempty"`
}

// Policy is the settings as Core's local history requests take them.
func (s LocalHistorySettings) Policy() core.HistoryPolicy {
	return core.HistoryPolicy{
		IgnoreRules:       core.HistoryIgnoreRules{PathPatterns: s.IgnorePatterns, PathRegexes: s.IgnoreRegexes},
		StorageLimitBytes: uint64(max(s.LimitMegabytes, 0)) << 20,
	}
}

// LocalHistorySource is the open project's local history as the settings window reaches it.
// Every method runs off the window thread and returns once ctx ends.
type LocalHistorySource interface {
	// Preview has Core check rules and, for a path that is not empty, say which of them keeps
	// that project-relative path out of the history and whether Git ignores it.
	Preview(ctx context.Context, rules core.HistoryIgnoreRules, path string) (core.HistoryIgnorePreview, error)
	// Usage measures the open project's history and the limit Core keeps it under for
	// limitMegabytes; open is false when no project is open.
	Usage(ctx context.Context, limitMegabytes int) (usage core.HistoryUsage, open bool, err error)
	// Clear deletes every snapshot of the open project's history.
	Clear(ctx context.Context) error
}

// localHistoryPreviewDelay is how long the rules and the test path rest before Core checks
// them, so typing does not start a check per key.
const localHistoryPreviewDelay = 200 * time.Millisecond

// localHistoryTimeout bounds one call to the project's history.
const localHistoryTimeout = 10 * time.Second

// defaultLimitMegabytes is Core's default history limit, which the stepper starts from when
// neither the field nor the measured limit gives one.
const defaultLimitMegabytes = 100

// limitStepMegabytes is how far one press of the limit stepper moves the limit.
const limitStepMegabytes = 10

// modeButton is one choice of the wildcard and regular expression switch: filled when it is
// the list shown, outlined otherwise. It reports whether this paint delivers a click.
func modeButton(c ui.C, part, label string, selected bool) bool {
	if selected {
		return ui.Button(c.Part(part), label).Small().Clicked()
	}
	return ui.Button(c.Part(part), label).Outline().Small().Clicked()
}

// localHistoryPreviewKey is what one preview checks: the drafts' raw lines, so the line numbers
// of errors and matches are the lines the user sees, and the test path.
type localHistoryPreviewKey struct {
	patterns, regexes, path string
}

// localHistoryStorage is the open project's history size and the state of a clear.
type localHistoryStorage struct {
	// known is set once a measure came back; open says a project was open for it.
	known, open bool
	usage       core.HistoryUsage
	// clearing is a clear in flight; clearFailed says the last one failed.
	clearing, clearFailed bool
}

// localHistoryAsync is the card's work off the window thread: the preview of the drafts and
// the project's storage. The page reads it under the lock; a later request makes an earlier
// one stale, so its result is dropped.
type localHistoryAsync struct {
	mu sync.Mutex
	// previewRun numbers the previews; asked is the key of the latest.
	previewRun int
	asked      localHistoryPreviewKey
	// preview is the latest result for shown, previewErr its failure.
	preview    *core.HistoryIgnorePreview
	shown      localHistoryPreviewKey
	previewErr error
	usageRun   int
	storage    localHistoryStorage
}

// localHistoryDraft is the local history card's unsaved edit. The card fills it from the stored
// settings when it is first shown and after each apply; Apply hands it to the owner.
type localHistoryDraft struct {
	loaded                    bool
	patterns, regexes, limit  ui.Field
	path                      ui.Field
	failure                   string
	confirmClear, wantedUsage bool
	// regexMode shows the regular expression list instead of the wildcard list.
	regexMode bool
	// builtIns are Core's default wildcard rules as the last preview reported them: a rule for
	// each folder hidden from the tree, Core's own and those the enabled plugins declare. shown are
	// the ones the wildcard list displays, and loadedPatterns the text it was loaded with: a
	// list nobody has edited yet picks up the built-in rules when they first arrive.
	builtIns, shown []string
	loadedPatterns  string
	async           localHistoryAsync
}

// load puts the stored settings in the draft, with the built-in rules builtIns shown in the
// wildcard list.
func (d *localHistoryDraft) load(stored LocalHistorySettings, builtIns []string) {
	d.loaded = true
	d.loadPatterns(stored, builtIns)
	d.regexes.SetText(strings.Join(stored.IgnoreRegexes, "\n"))
	limit := ""
	if stored.LimitMegabytes > 0 {
		limit = strconv.Itoa(stored.LimitMegabytes)
	}
	d.limit.SetText(limit)
	d.failure = ""
}

// loadPatterns puts the wildcard list in the draft: each built-in rule as a line, "!" where the
// stored rules turn it off, then the stored rules that are not such a switch.
func (d *localHistoryDraft) loadPatterns(stored LocalHistorySettings, builtIns []string) {
	d.shown = builtIns
	d.loadedPatterns = strings.Join(wildcardLines(stored.IgnorePatterns, builtIns), "\n")
	d.patterns.SetText(d.loadedPatterns)
}

// settings is what the draft would store: each field's lines trimmed, without blank ones.
// The wildcard list turns a built-in rule off when its line was deleted, and back on when its
// "!" line was. ok is false when the limit is not a positive whole number.
func (d *localHistoryDraft) settings(stored LocalHistorySettings) (LocalHistorySettings, bool) {
	out := LocalHistorySettings{
		IgnorePatterns: wildcardRules(ruleEntries(d.patterns.Text()), stored.IgnorePatterns, d.shown),
		IgnoreRegexes:  ruleEntries(d.regexes.Text()),
	}
	if text := strings.TrimSpace(d.limit.Text()); text != "" {
		megabytes, err := strconv.Atoi(text)
		if err != nil || megabytes < 1 {
			return out, false
		}
		out.LimitMegabytes = megabytes
	}
	return out, true
}

// ruleEntries is text's lines, trimmed, without blank ones.
func ruleEntries(text string) []string {
	var out []string
	for _, line := range strings.Split(text, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			out = append(out, line)
		}
	}
	return out
}

// disablesBuiltIn reports whether entry is a "!" rule that turns builtIn (a "**/name/" glob)
// off. Core also reads the bare name, so "!name" counts too.
func disablesBuiltIn(entry, builtIn string) bool {
	rest, ok := strings.CutPrefix(strings.TrimSpace(entry), "!")
	if !ok {
		return false
	}
	rest = strings.TrimSpace(rest)
	name := strings.TrimSuffix(strings.TrimPrefix(builtIn, "**/"), "/")
	return strings.EqualFold(rest, builtIn) || strings.EqualFold(rest, name)
}

// switchedOff is the stored rule that turns builtIn off, or false when none does.
func switchedOff(stored []string, builtIn string) bool {
	return slices.ContainsFunc(stored, func(entry string) bool { return disablesBuiltIn(entry, builtIn) })
}

// wildcardLines is the wildcard list as the card shows it: each built-in rule as its glob, or
// as a "!" line where stored turns it off, then the stored rules that are not those switches.
func wildcardLines(stored, builtIns []string) []string {
	var out []string
	for _, builtIn := range builtIns {
		if switchedOff(stored, builtIn) {
			out = append(out, "!"+builtIn)
		} else {
			out = append(out, builtIn)
		}
	}
	for _, entry := range stored {
		if !slices.ContainsFunc(builtIns, func(builtIn string) bool { return disablesBuiltIn(entry, builtIn) }) {
			out = append(out, entry)
		}
	}
	return out
}

// wildcardRules is what the wildcard list stores, given its lines, the stored rules and the
// built-in rules the list showed. A built-in line left out turns its rule off, a "!" line keeps
// it off, and a "!" line removed turns it back on. Lines that are not built-in rules are kept
// in order after those switches.
func wildcardRules(lines, stored, shown []string) []string {
	if len(shown) == 0 {
		return lines
	}
	used := make([]bool, len(lines))
	var out []string
	for _, builtIn := range shown {
		on, off := false, false
		for i, line := range lines {
			switch {
			case strings.EqualFold(line, builtIn):
				used[i], on = true, true
			case disablesBuiltIn(line, builtIn):
				used[i], off = true, true
			}
		}
		switch {
		case off:
			out = append(out, "!"+builtIn)
		case !on && !switchedOff(stored, builtIn):
			out = append(out, "!"+builtIn)
		}
	}
	for i, line := range lines {
		if !used[i] {
			out = append(out, line)
		}
	}
	return out
}

// previewRules is the drafts as the preview sends them: every line as typed, blank ones
// included, so an index Core answers with is the line's number less one.
func (k localHistoryPreviewKey) previewRules() core.HistoryIgnoreRules {
	lines := func(text string) []string {
		if strings.TrimSpace(text) == "" {
			return nil
		}
		return strings.Split(text, "\n")
	}
	return core.HistoryIgnoreRules{PathPatterns: lines(k.patterns), PathRegexes: lines(k.regexes)}
}

// localHistoryCard is the General page's local history card: how much space the open project's
// history takes and its limit, a way to clear it, the wildcard and regular expression rules for
// files it does not record, with Core's built-in rules and the rules Core cannot read, and a
// test path that says whether a file is recorded and whether Git ignores it. Opening it writes
// nothing; Apply stores the rules and the limit, and Clear asks first.
func (w *window) localHistoryCard(c ui.C) {
	language := w.marketLanguage()
	d := &w.localHistory
	stored := w.sess.values.LocalHistory
	if !d.loaded {
		d.load(stored, d.builtIns)
		d.wantedUsage = true
	}
	if d.wantedUsage {
		d.wantedUsage = false
		w.measureLocalHistory()
	}
	d.async.mu.Lock()
	storage, preview, shown, previewErr := d.async.storage, d.async.preview, d.async.shown, d.async.previewErr
	d.async.mu.Unlock()
	// The built-in rules arrive with the first preview. A list nobody has edited yet shows them.
	if preview != nil && len(preview.BuiltInIgnorePatterns) > 0 {
		d.builtIns = preview.BuiltInIgnorePatterns
		if len(d.shown) == 0 && d.patterns.Text() == d.loadedPatterns {
			d.loadPatterns(stored, d.builtIns)
		}
	}
	key := localHistoryPreviewKey{patterns: strings.Join(wildcardRules(ruleEntries(d.patterns.Text()), stored.IgnorePatterns, d.shown), "\n"), regexes: d.regexes.Text(), path: strings.TrimSpace(d.path.Text())}
	w.previewLocalHistory(key)

	label := func(text string) {
		ui.Row(c).WidthPercent(34).Shrink(1).MinWidth(0).Items(ui.Center).Children(func() {
			ui.Text(c, text).FontSize(12).Color(w.pal.text).Ellipsis()
		})
	}
	w.card(c, i18n.Shared(language, "native.localHistory"), i18n.Shared(language, "desktop.settings.localHistory.help"), func() {
		ui.Column(c).FillWidth().Gap(8).Children(func() {
			ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(12).Children(func() {
				label(i18n.Shared(language, "native.used.variant3"))
				switch {
				case !storage.known:
				case !storage.open:
					ui.Wrap(c, i18n.Shared(language, "native.openAProjectToSeeHowMuchSpaceItsHistoryUses")).FontSize(12).Color(w.pal.muted).Grow(1).MinWidth(0)
				default:
					ui.Text(c, byteSize(storage.usage.UsedBytes)+" / "+byteSize(storage.usage.LimitBytes)).FontSize(12).Color(w.pal.text).Grow(1).MinWidth(0).Ellipsis()
					text := i18n.Shared(language, "native.clearProjectHistory")
					if storage.clearing {
						text = i18n.Shared(language, "native.clearing")
					}
					if ui.Button(c.Part("clear"), text).Outline().Small().Disabled(storage.clearing || storage.usage.UsedBytes == 0).Clicked() {
						d.confirmClear = true
					}
				}
			})
			if storage.clearFailed {
				ui.Row(c).FillWidth().Items(ui.Center).Gap(8).Children(func() {
					ui.Wrap(c, i18n.Shared(language, "history.clearFailed")).FontSize(12).Color(w.pal.danger).Grow(1).MinWidth(0)
					if ui.Button(c.Part("clear-retry"), i18n.Shared(language, "ui.retry")).Ghost().Small().Clicked() {
						d.confirmClear = true
					}
				})
			}
			ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(6).Children(func() {
				ui.Row(c).WidthPercent(34).Shrink(1).MinWidth(0).Items(ui.Center).Gap(6).Children(func() {
					ui.Text(c, i18n.Shared(language, "native.limitPerProject")).FontSize(12).Color(w.pal.text).Ellipsis()
					w.infoButton(c, i18n.Shared(language, "native.whenTheLimitIsReachedTheOldestVersionsAreRemovedFirst"))
				})
				// An empty field keeps Core's default, which the placeholder shows once the
				// project's history was measured.
				placeholder := ""
				if storage.open && stored.LimitMegabytes == 0 {
					placeholder = strconv.FormatUint(storage.usage.LimitBytes>>20, 10)
				}
				ui.TextField(c.Part("limit"), &d.limit, i18n.Shared(language, "native.localHistoryLimitPerProject"), placeholder).Width(80)
				ui.Text(c, "MB").FontSize(12).Color(w.pal.text).Shrink(0)
				// The stepper starts from the limit shown, or from Core's default when the field is empty.
				stepLimit := func(delta int) {
					current, err := strconv.Atoi(strings.TrimSpace(d.limit.Text()))
					if err != nil {
						current = defaultLimitMegabytes
						if shownDefault, parseErr := strconv.Atoi(placeholder); parseErr == nil {
							current = shownDefault
						}
					}
					d.limit.SetText(strconv.Itoa(max(1, current+delta*limitStepMegabytes)))
				}
				if ui.Button(c.Part("limit-down"), "−").Outline().Small().Clicked() {
					stepLimit(-1)
				}
				if ui.Button(c.Part("limit-up"), "+").Outline().Small().Clicked() {
					stepLimit(1)
				}
				ui.Spacer(c)
			})
			ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(8).Children(func() {
				// One list at a time, as IDEA's wildcard and regular expression switch.
				if modeButton(c, "mode-wildcard", i18n.Shared(language, "native.wildcard"), !d.regexMode) {
					d.regexMode = false
				}
				if modeButton(c, "mode-regex", i18n.Shared(language, "native.regularExpression.variant2"), d.regexMode) {
					d.regexMode = true
				}
				ui.Spacer(c)
				if d.regexMode {
					w.infoButton(c, i18n.Shared(language, "desktop.settings.localHistory.regexHelp"))
				} else {
					w.infoButton(c, i18n.Shared(language, "desktop.settings.localHistory.wildcardHelp")+" "+i18n.Shared(language, "desktop.settings.localHistory.builtInsHelp"))
				}
			})
			if d.regexMode {
				ui.TextArea(c.Part("regexes"), &d.regexes, i18n.Shared(language, "native.regularExpressionIgnoreRules"), "(test|spec)/").FillWidth().Height(96)
			} else {
				ui.TextArea(c.Part("patterns"), &d.patterns, i18n.Shared(language, "native.wildcardIgnoreRules"), "**/generated/").FillWidth().Height(120)
			}
			if d.regexMode && preview != nil && shown.regexes == key.regexes {
				for _, failure := range preview.RegexErrors {
					text := i18n.SharedFormat(language, "native.lineLldIsNotAValidRegularExpressionAndIsSkipped", map[string]string{"arg1": strconv.Itoa(failure.Index + 1)})
					ui.Wrap(c, text+" "+failure.Message).FontSize(12).Color(w.pal.danger)
				}
			}
			ui.Row(c).FillWidth().Height(28).Items(ui.Center).Gap(12).Children(func() {
				ui.Row(c).WidthPercent(34).Shrink(1).MinWidth(0).Items(ui.Center).Gap(6).Children(func() {
					ui.Text(c, i18n.Shared(language, "native.testPath")).FontSize(12).Color(w.pal.text).Ellipsis()
					w.infoButton(c, i18n.Shared(language, "native.typeAPathInsideTheProjectToCheckItAgainstTheRulesAboveAsYouEditThemWhetherLocalH0f31e93916"))
				})
				ui.TextField(c.Part("path"), &d.path, i18n.Shared(language, "native.testPath"), "src/generated/api.txt").Grow(1).MinWidth(0)
			})
			if key.path != "" && shown == key {
				for _, line := range localHistoryVerdict(language, preview, previewErr) {
					ui.Wrap(c, line.text).FontSize(12).Color(w.lineColor(line.tone))
				}
			}
			if d.failure != "" {
				ui.Wrap(c, d.failure).FontSize(12).Color(w.pal.danger)
			}
			ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
				ui.Spacer(c)
				if ui.Button(c.Part("revert"), i18n.Shared(language, "desktop.settings.network.revert")).Outline().Clicked() {
					d.load(stored, d.builtIns)
				}
				if ui.Button(c.Part("apply"), i18n.Shared(language, "desktop.settings.network.apply")).Clicked() {
					w.applyLocalHistory(language)
				}
			})
		})
	})
	if d.confirmClear {
		ui.Modal(c, &d.confirmClear, i18n.Shared(language, "native.clearThisProjectSLocalHistory"), ui.ModalSpec{}, func() {
			ui.Wrap(c, i18n.Shared(language, "native.everySavedVersionOfThisProjectSFilesIsDeletedOpenFilesAreNotChanged")).FontSize(12).Color(w.pal.text)
		}, func() {
			if ui.Button(c, i18n.Shared(language, "desktop.pluginSettings.actionCancel")).Outline().Clicked() {
				d.confirmClear = false
			}
			if ui.Button(c, i18n.Shared(language, "ui.clear")).Destructive().Clicked() {
				d.confirmClear = false
				w.clearLocalHistory()
			}
		})
	}
}

// verdictTone is how a line of the test path's verdict reads.
type verdictTone uint8

const (
	verdictPlain verdictTone = iota
	verdictWarning
	verdictMuted
)

// lineColor is the color of a verdict line of tone.
func (w *window) lineColor(tone verdictTone) gfx.Color {
	switch tone {
	case verdictWarning:
		return w.pal.danger
	case verdictMuted:
		return w.pal.muted
	}
	return w.pal.text
}

// verdictLine is one line the test path's verdict shows.
type verdictLine struct {
	text string
	tone verdictTone
}

// localHistoryVerdict says what Core found for the test path: whether local history records
// it, or which rule keeps it out, and whether Git ignores it, which local history does not
// follow. A path Core refuses as outside the project says so.
func localHistoryVerdict(language i18n.Language, preview *core.HistoryIgnorePreview, err error) []verdictLine {
	if err != nil {
		var failure *core.Error
		if errors.As(err, &failure) && failure.Code == core.CodeInvalidRequest {
			return []verdictLine{{i18n.Shared(language, "native.aTestPathMustStayInsideTheCurrent"), verdictWarning}}
		}
		return []verdictLine{{err.Error(), verdictWarning}}
	}
	if preview == nil {
		return nil
	}
	result, tone := i18n.Shared(language, "native.recorded"), verdictPlain
	if match := preview.Matched; match != nil {
		tone = verdictWarning
		switch match.Kind {
		case "hidden":
			result = i18n.Shared(language, "native.hiddenInTheProjectTreeNotRecorded")
		case "pattern":
			result = i18n.SharedFormat(language, "native.ignoredByWildcardRule", map[string]string{"arg1": match.Pattern})
		case "regex":
			result = i18n.SharedFormat(language, "native.ignoredByRegularExpressionLineLld", map[string]string{"arg1": strconv.Itoa(match.Index + 1)})
		}
	}
	lines := []verdictLine{{i18n.SharedFormat(language, "native.localHistoryFormat", map[string]string{"arg1": result}), tone}}
	if preview.GitIgnored != nil {
		git := i18n.Shared(language, "native.gitNotIgnored")
		if *preview.GitIgnored {
			git = i18n.Shared(language, "native.gitIgnored")
		}
		lines = append(lines, verdictLine{git, verdictMuted})
	}
	return lines
}

// byteSize is a size in binary units, the ones Core sets the history limit in, so its default
// reads 100 MB: whole kilobytes below a megabyte, then megabytes and gigabytes with one
// decimal unless they are whole.
func byteSize(bytes uint64) string {
	unit := func(value float64, suffix string) string {
		if value == float64(int64(value)) {
			return strconv.FormatInt(int64(value), 10) + " " + suffix
		}
		return strconv.FormatFloat(value, 'f', 1, 64) + " " + suffix
	}
	switch {
	case bytes < 1<<20:
		return strconv.FormatUint((bytes+1023)>>10, 10) + " KB"
	case bytes < 1<<30:
		return unit(float64(bytes)/(1<<20), "MB")
	}
	return unit(float64(bytes)/(1<<30), "GB")
}

// applyLocalHistory hands the draft to the settings owner and shows it as stored; the project's
// history is measured again under the new limit.
func (w *window) applyLocalHistory(language i18n.Language) {
	d := &w.localHistory
	next, ok := d.settings(w.sess.values.LocalHistory)
	if !ok {
		d.failure = i18n.Shared(language, "desktop.settings.localHistory.invalidLimit")
		return
	}
	w.sess.values.LocalHistory = next
	if w.ctrl.opts.SetLocalHistory != nil {
		w.ctrl.opts.SetLocalHistory(next)
	}
	d.load(next, d.builtIns)
	w.measureLocalHistory()
}

// previewLocalHistory has Core check key once it rests for localHistoryPreviewDelay. A key
// already asked for is not asked again.
func (w *window) previewLocalHistory(key localHistoryPreviewKey) {
	source := w.ctrl.opts.LocalHistory
	a := &w.localHistory.async
	a.mu.Lock()
	if source == nil || (a.previewRun > 0 && a.asked == key) {
		a.mu.Unlock()
		return
	}
	a.previewRun++
	run := a.previewRun
	a.asked = key
	a.mu.Unlock()
	inv := &w.inv
	delay := localHistoryPreviewDelay
	if run == 1 {
		delay = 0
	}
	time.AfterFunc(delay, func() {
		a.mu.Lock()
		current := run == a.previewRun
		a.mu.Unlock()
		if !current {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), localHistoryTimeout)
		defer cancel()
		preview, err := source.Preview(ctx, key.previewRules(), key.path)
		a.mu.Lock()
		if run == a.previewRun {
			a.shown, a.previewErr = key, err
			if err == nil {
				a.preview = &preview
			} else if a.preview != nil {
				// A refused path keeps the rules' last reading: the built-ins and their errors.
				kept := *a.preview
				kept.Matched, kept.GitIgnored = nil, nil
				a.preview = &kept
			}
		}
		a.mu.Unlock()
		inv.Invalidate()
	})
}

// measureLocalHistory measures the open project's history under the stored limit, off the
// window thread.
func (w *window) measureLocalHistory() {
	source := w.ctrl.opts.LocalHistory
	if source == nil {
		return
	}
	limit, inv := w.sess.values.LocalHistory.LimitMegabytes, &w.inv
	go func() {
		w.localHistory.async.measure(source, limit)
		inv.Invalidate()
	}()
}

// measure has source measure the open project's history under limit and keeps the result
// unless a later measure started meanwhile. A failed measure keeps the last one.
func (a *localHistoryAsync) measure(source LocalHistorySource, limit int) {
	a.mu.Lock()
	a.usageRun++
	run := a.usageRun
	a.mu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), localHistoryTimeout)
	defer cancel()
	usage, open, err := source.Usage(ctx, limit)
	a.mu.Lock()
	defer a.mu.Unlock()
	if run == a.usageRun && err == nil {
		a.storage.known, a.storage.open, a.storage.usage = true, open, usage
	}
}

// clearLocalHistory deletes the open project's history off the window thread, then measures it
// again; a failure stays on the card with a way to try again.
func (w *window) clearLocalHistory() {
	source := w.ctrl.opts.LocalHistory
	a := &w.localHistory.async
	a.mu.Lock()
	if source == nil || a.storage.clearing {
		a.mu.Unlock()
		return
	}
	a.storage.clearing, a.storage.clearFailed = true, false
	a.mu.Unlock()
	limit, inv := w.sess.values.LocalHistory.LimitMegabytes, &w.inv
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), localHistoryTimeout)
		err := source.Clear(ctx)
		cancel()
		a.mu.Lock()
		a.storage.clearing, a.storage.clearFailed = false, err != nil
		a.mu.Unlock()
		a.measure(source, limit)
		inv.Invalidate()
	}()
}
