package settingswindow

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginsettings"
)

type actionFormLoader struct {
	calls   chan bool
	blocked bool
	saves   int
	// returned is closed when a blocked action returns after its context ended.
	returned chan struct{}
}

func (s *actionFormLoader) Load(context.Context, string) (pluginservice.SettingsEditor, error) {
	return pluginservice.SettingsEditor{}, errors.New("unexpected load")
}
func (s *actionFormLoader) Save(context.Context, pluginservice.SettingsEditor, string, []core.PluginSettingEdit) (pluginsettings.SaveResult, error) {
	s.saves++
	return pluginsettings.SaveResult{}, errors.New("action attempted save")
}
func (s *actionFormLoader) Action(ctx context.Context, _ pluginservice.SettingsEditor, id string, confirmed bool) (pluginservice.SettingsActionResult, error) {
	s.calls <- confirmed
	if id != "refresh" {
		return pluginservice.SettingsActionResult{}, errors.New("retargeted action")
	}
	plan := core.PluginSettingsActionPlan{Kind: "confirmationRequired", ActionID: id, Title: "Fixture action"}
	if !confirmed {
		return pluginservice.SettingsActionResult{Plan: plan}, nil
	}
	if s.blocked {
		<-ctx.Done()
		if s.returned != nil {
			close(s.returned)
		}
		return pluginservice.SettingsActionResult{}, ctx.Err()
	}
	plan.Kind = "invoke"
	return pluginservice.SettingsActionResult{Plan: plan, Completed: true}, nil
}

// formWindow opens a settings window whose plugin form uses loader, as a loaded form with one
// control holding draft.
func formWindow(t *testing.T, loader PluginSettingsLoader, draft string) (*window, *windowDriver, *pluginSettingsForm) {
	t.Helper()
	w := newWindow(NewController(Options{PluginSettings: loader}), Values{})
	d := openWindow(t, w)
	p := w.pluginSettings
	p.loaded = true
	p.controls[0] = make([]pluginSettingControl, 1)
	p.controls[0][0].text = draft
	return w, d, p
}

func TestSettingsActionConfirmationDoesNotSaveOrReplaceDrafts(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	loader := &actionFormLoader{calls: make(chan bool, 2)}
	_, d, p := formWindow(t, loader, "unsaved draft")
	p.act("refresh", false)
	d.until("the confirmation", func() bool { return p.actionConfirmation != nil })
	select {
	case confirmed := <-loader.calls:
		if confirmed {
			t.Fatal("confirmation was bypassed")
		}
	case <-ctx.Done():
		t.Fatal("confirmation was not requested")
	}
	if p.actionComplete {
		t.Fatal("confirmation phase invoked an action")
	}
	p.act("refresh", true)
	d.until("the action", func() bool { return p.actionComplete })
	select {
	case confirmed := <-loader.calls:
		if !confirmed {
			t.Fatal("confirmed action lost its confirmation")
		}
	case <-ctx.Done():
		t.Fatal("action was not requested")
	}
	if p.actionConfirmation != nil || p.failed != nil {
		t.Fatalf("action terminal: %+v", p)
	}
	if p.controls[0][0].text != "unsaved draft" || loader.saves != 0 {
		t.Fatal("action changed or saved an editor draft")
	}
}

func TestSettingsActionCancellationAndPageCloseCannotPublishLateSuccess(t *testing.T) {
	for _, closed := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancel", true: "page-close"}[closed], func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			loader := &actionFormLoader{calls: make(chan bool, 1), blocked: true, returned: make(chan struct{})}
			w, d, p := formWindow(t, loader, "")
			p.act("refresh", true)
			w.inv.Invalidate()
			d.pump()
			select {
			case <-loader.calls:
			case <-ctx.Done():
				t.Fatal("action did not start")
			}
			if closed {
				// Closing the window ends the page and cancels its effects.
				d.driver.Close()
			} else {
				p.stop()
			}
			stopsWithin(t, loader.returned, "the cancelled action")
			if !closed {
				d.until("the cancellation", func() bool { return !p.running })
			} else {
				w.inv.Invalidate()
			}
			if p.actionComplete || p.failed != nil {
				t.Fatal("cancelled action published an error or success")
			}
			if !closed && !p.actionCanceled {
				t.Fatal("explicit cancellation was not presented")
			}
			if loader.saves != 0 {
				t.Fatal("cancellation saved settings")
			}
		})
	}
}
