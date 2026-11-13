package settingswindow

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/shortcuts"
	"github.com/vivaui/viva/ui"
	"time"
)

type schemeDraft struct {
	ready, open   bool
	operation, id string
	name          ui.Field
	failure       string
}

func (w *window) reportEssentialsFailure(_ string, err error) { reportSettingsError(w.ctrl.opts, err) }

func (w *window) reduceScheme(request core.KeymapSchemeRequest) bool {
	request.State = w.sess.values.KeymapSchemes
	request.Current = w.sess.values.Keymap
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	result, err := core.NewClient().ReduceKeymapSchemes(ctx, request)
	if err != nil {
		message := i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.failed")
		var failure *core.Error
		if errors.As(err, &failure) {
			switch failure.Details {
			case "invalid_name":
				message = i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.invalidName")
			case "duplicate_name":
				message = i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.duplicateName")
			case "too_many_schemes":
				message = i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.limit")
			}
		}
		w.scheme.failure = message
		w.reportEssentialsFailure("keymap_schemes", err)
		return false
	}
	w.sess.values.KeymapSchemes = result.State
	w.sess.values.Keymap = shortcuts.Overrides(result.Bindings)
	w.scheme.failure = ""
	w.keymap.recording, w.keymap.message = "", ""
	if set := w.ctrl.opts.SetKeymapSchemes; set != nil && request.Operation != "" {
		set(result)
	}
	return true
}

func (w *window) updateKeymapScheme(bindings shortcuts.Overrides) bool {
	// An explicit empty object clears a scheme instead of retaining an old map.
	if bindings == nil {
		bindings = shortcuts.Overrides{}
	}
	return w.reduceScheme(core.KeymapSchemeRequest{Operation: "update", Bindings: bindings})
}

func (w *window) keymapSchemeCard(c ui.C) {

	s := &w.scheme
	if !s.ready {
		s.ready = true
		w.reduceScheme(core.KeymapSchemeRequest{})
	}
	state := w.sess.values.KeymapSchemes
	w.card(c, i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.scheme"), "", func() {
		ids := make([]string, 0, len(state.Schemes))
		for _, scheme := range state.Schemes {
			ids = append(ids, scheme.ID)
		}
		selected := state.Active
		ui.Row(c).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			if ui.Select(c.Part("scheme"), &selected, ids, func(id string) string {
				for _, scheme := range state.Schemes {
					if scheme.ID == id {
						if id == "default" {
							return i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.default")
						}
						return scheme.Name
					}
				}
				return id
			}).Width(selectWidth).Label(i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.scheme")).Changed() {
				w.reduceScheme(core.KeymapSchemeRequest{Operation: "select", ID: selected})
			}
		})
		ui.Row(c.Part("scheme-actions")).FillWidth().Gap(8).Items(ui.Center).Children(func() {
			begin := func(operation string) {
				s.operation, s.id, s.open = operation, state.Active, true
				s.name.SetText("")
				s.failure = ""
				for _, scheme := range state.Schemes {
					if scheme.ID == s.id && operation == "rename" {
						s.name.SetText(scheme.Name)
					}
				}
			}
			if ui.Button(c, i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.saveAs")).Outline().Small().Clicked() {
				begin("saveAs")
			}
			if ui.Button(c, i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.rename")).Outline().Small().Disabled(state.Active == "default").Clicked() {
				begin("rename")
			}
			if ui.Button(c, i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.delete")).Outline().Small().Disabled(state.Active == "default").Clicked() {
				begin("delete")
			}
		})
		if s.failure != "" && !s.open {
			ui.Wrap(c, s.failure).Color(w.pal.danger).FontSize(12)
		}
	})
	if !s.open {
		return
	}
	title := i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.newTitle")
	if s.operation == "rename" {
		title = i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.renameTitle")
	}
	if s.operation == "delete" {
		title = i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.delete")
	}
	ui.ModalWith(c.Part("scheme-name"), &s.open, title, ui.ModalSpec{Width: 410}, func() {
		if s.operation != "delete" {
			ui.TextField(c, &s.name, i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.name"), "").FillWidth()
		}
		if s.failure != "" {
			ui.Wrap(c, s.failure).FontSize(12).Color(w.pal.danger)
		}
	}, func() {
		if ui.Button(c, w.text.Settings.Cancel).Outline().Clicked() {
			s.open = false
		}
		if ui.Button(c, w.text.Settings.OK).Clicked() {
			id := s.id
			if s.operation == "saveAs" {
				var random [16]byte
				if _, err := rand.Read(random[:]); err != nil {
					w.reportEssentialsFailure("keymap_schemes", err)
					s.failure = i18n.Shared(w.marketLanguage(), "desktop.keymapSchemes.failed")
					return
				}
				id = hex.EncodeToString(random[:])
			}
			if w.reduceScheme(core.KeymapSchemeRequest{Operation: s.operation, ID: id, Name: s.name.Text()}) {
				s.open = false
			}
		}
	})
}
