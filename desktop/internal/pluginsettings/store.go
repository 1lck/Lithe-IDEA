// Package pluginsettings connects Core-owned plugin preferences to native
// application/workspace storage. It never merges or interprets setting values.
package pluginsettings

import (
	"context"
	"encoding/json"
	"errors"
	"os"

	"github.com/1lck/Lithe-IDEA/desktop/internal/configfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

var ErrNoProject = errors.New("plugin project settings have no workspace source")

// Kernel owns document validation, inheritance, edit rules, and effect planning.
type Kernel interface {
	ReadPluginSettingsState(context.Context, json.RawMessage, *string, *string, *core.PluginSettingsLocalizationRequest) (core.PluginSettingsState, error)
	EditPluginSettings(context.Context, json.RawMessage, string, *string, []core.PluginSettingEdit) (core.PluginSettingsEditPlan, error)
}

// Store uses a platform-owned preference directory, never an installation path.
type Store struct {
	kernel     Kernel
	globalRoot string
}

func New(kernel Kernel, preferenceDirectory string) *Store {
	return &Store{kernel: kernel, globalRoot: preferenceDirectory}
}

// Presentation selects the interface language of a settings view. Package is
// the installed plugin directory; translations are only read from it, never
// written, so the installed package stays byte-identical.
type Presentation struct {
	Language string
	Package  string
}

// LocalizationReadFailure is a candidate translation that exists but could not
// be read. The adapter skips it, so Core falls back to the next candidate or to
// manifest text; the caller owns logging it.
type LocalizationReadFailure struct {
	Path string
	Err  error
}

// Snapshot exposes only Core's projection and source locations. Whole documents
// and baselines stay private, separate from editable view state.
type Snapshot struct {
	State        core.PluginSettingsState
	workspace    string
	globalRoot   string
	manifest     json.RawMessage
	presentation *Presentation
	global       configfile.Snapshot
	project      configfile.Snapshot
	unreadable   []LocalizationReadFailure
}

func (s Snapshot) Workspace() string { return s.workspace }

// LocalizationReadFailures lists candidates skipped by this load. Files Core
// refused are in State.Localization.Rejected instead.
func (s Snapshot) LocalizationReadFailures() []LocalizationReadFailure {
	return append([]LocalizationReadFailure(nil), s.unreadable...)
}

// PreferenceDirectory is the private native storage owner, not view metadata.
func (s Snapshot) PreferenceDirectory() string { return s.globalRoot }

func (s *Store) PreferenceDirectory() string { return s.globalRoot }

func (s Snapshot) GlobalPath() string { return s.global.Path() }
func (s Snapshot) ProjectPath() string {
	if s.workspace == "" {
		return ""
	}
	return s.project.Path()
}

// SaveResult distinguishes a committed source from readback/cleanup failures.
// A caller must keep its draft and invalidate the baseline if Readback is nil;
// it must not blindly retry a committed publication against the old snapshot.
type SaveResult struct {
	Committed bool
	Readback  *Snapshot
	Effects   []string
}

// Load reads actual sources after asking Core what to read and how much. A
// missing project is explicit; malformed or unreadable files never become empty.
// Text stays as written in the manifest; use LoadPresented for a settings view.
func (s *Store) Load(ctx context.Context, manifest json.RawMessage, workspace string) (Snapshot, error) {
	return s.load(ctx, manifest, workspace, nil)
}

// LoadPresented also applies the package translation Core selects for the
// language. Save readback keeps the same presentation.
func (s *Store) LoadPresented(ctx context.Context, manifest json.RawMessage, workspace string, presentation Presentation) (Snapshot, error) {
	return s.load(ctx, manifest, workspace, &presentation)
}

func (s *Store) load(ctx context.Context, manifest json.RawMessage, workspace string, presentation *Presentation) (Snapshot, error) {
	var localization *core.PluginSettingsLocalizationRequest
	if presentation != nil {
		localization = &core.PluginSettingsLocalizationRequest{Language: presentation.Language}
	}
	policy, err := s.kernel.ReadPluginSettingsState(ctx, manifest, nil, nil, localization)
	if err != nil {
		return Snapshot{}, err
	}
	snapshot := Snapshot{workspace: workspace, globalRoot: s.globalRoot, manifest: append(json.RawMessage(nil), manifest...), presentation: presentation}
	translate := policy.Localization != nil && policy.Localization.ReadRequired
	if !policy.Storage.ReadRequired && !translate {
		snapshot.State = policy
		return snapshot, nil
	}
	if translate {
		localization.Files, snapshot.unreadable, err = readTranslations(ctx, presentation.Package, *policy.Localization)
		if err != nil {
			return Snapshot{}, err
		}
	}
	if !policy.Storage.ReadRequired {
		snapshot.State, err = s.kernel.ReadPluginSettingsState(ctx, manifest, nil, nil, localization)
		if err != nil {
			return Snapshot{}, err
		}
		return snapshot, nil
	}
	snapshot.global, err = configfile.Capture(ctx, s.globalRoot, policy.Storage.GlobalRelativePath, policy.Storage.MaximumBytes)
	if err != nil {
		return Snapshot{}, err
	}
	global, err := snapshot.global.Text()
	if err != nil {
		return Snapshot{}, err
	}
	var project *string
	if workspace != "" {
		info, statErr := os.Stat(workspace)
		if statErr != nil {
			return Snapshot{}, errors.Join(ErrNoProject, statErr)
		}
		if !info.IsDir() {
			return Snapshot{}, errors.Join(ErrNoProject, configfile.ErrTarget)
		}
		snapshot.project, err = configfile.Capture(ctx, workspace, policy.Storage.ProjectRelativePath, policy.Storage.MaximumBytes)
		if err != nil {
			return Snapshot{}, err
		}
		project, err = snapshot.project.Text()
		if err != nil {
			return Snapshot{}, err
		}
	}
	snapshot.State, err = s.kernel.ReadPluginSettingsState(ctx, manifest, global, project, localization)
	if err != nil {
		return Snapshot{}, err
	}
	return snapshot, nil
}

// readTranslations returns every candidate present in the package. A missing
// candidate is the normal case; any other failure skips only that file.
func readTranslations(ctx context.Context, packageDirectory string, plan core.PluginSettingsLocalization) (map[string]string, []LocalizationReadFailure, error) {
	files := map[string]string{}
	var unreadable []LocalizationReadFailure
	for _, candidate := range plan.Candidates {
		source, err := configfile.Capture(ctx, packageDirectory, candidate, plan.MaximumBytes)
		var text *string
		if err == nil {
			text, err = source.Text()
		}
		if ctxErr := ctx.Err(); ctxErr != nil {
			return nil, nil, ctxErr
		}
		if err != nil {
			unreadable = append(unreadable, LocalizationReadFailure{Path: candidate, Err: err})
			continue
		}
		if text != nil {
			files[candidate] = *text
		}
	}
	return files, unreadable, nil
}

// Save changes one captured layer only. check binds the plugin registration and
// workspace to the initiating owner; it runs before planning and publication.
func (s *Store) Save(ctx context.Context, snapshot Snapshot, scope string, edits []core.PluginSettingEdit, check func() error) (SaveResult, error) {
	if err := ctx.Err(); err != nil {
		return SaveResult{}, err
	}
	if check != nil {
		if err := check(); err != nil {
			return SaveResult{}, err
		}
	}
	var source configfile.Snapshot
	switch scope {
	case "global":
		source = snapshot.global
	case "project":
		source = snapshot.project
	}
	document, err := source.Text()
	if err != nil {
		return SaveResult{}, err
	}
	plan, err := s.kernel.EditPluginSettings(ctx, snapshot.manifest, scope, document, edits)
	if err != nil {
		return SaveResult{}, err
	}
	if scope == "project" && snapshot.workspace == "" {
		return SaveResult{}, ErrNoProject
	}
	var result SaveResult
	if plan.Delete {
		result.Committed, err = source.Remove(ctx, check)
	} else {
		result.Committed, err = source.Replace(ctx, []byte(plan.Document), check)
	}
	if err != nil && !result.Committed {
		return result, err
	}
	// Effects belong to the validated edit, but must not run before publication.
	result.Effects = plan.Effects
	readback, readErr := New(s.kernel, snapshot.globalRoot).load(ctx, snapshot.manifest, snapshot.workspace, snapshot.presentation)
	if readErr == nil {
		result.Readback = &readback
	}
	return result, errors.Join(err, readErr)
}
