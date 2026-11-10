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
		return pluginservice.SettingsActionResult{}, ctx.Err()
	}
	plan.Kind = "invoke"
	return pluginservice.SettingsActionResult{Plan: plan, Completed: true}, nil
}

func TestSettingsActionConfirmationDoesNotSaveOrReplaceDrafts(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	loader := &actionFormLoader{calls: make(chan bool, 2)}
	wake := make(chan struct{}, 1)
	p := newPluginSettingsForm(loader, func() { wake <- struct{}{} })
	p.loaded = true
	p.controls[0] = make([]pluginSettingControl, 1)
	p.controls[0][0].field.SetText("unsaved draft")
	finish := func() {
		t.Helper()
		select {
		case <-wake:
			p.drain()
		case <-ctx.Done():
			t.Fatal("action worker did not finish")
		}
	}
	p.act("refresh", false)
	finish()
	select {
	case confirmed := <-loader.calls:
		if confirmed {
			t.Fatal("confirmation was bypassed")
		}
	case <-ctx.Done():
		t.Fatal("confirmation was not requested")
	}
	if p.actionConfirmation == nil || p.actionComplete {
		t.Fatal("confirmation phase invoked an action")
	}
	p.act("refresh", true)
	finish()
	select {
	case confirmed := <-loader.calls:
		if !confirmed {
			t.Fatal("confirmed action lost its confirmation")
		}
	case <-ctx.Done():
		t.Fatal("action was not requested")
	}
	if !p.actionComplete || p.actionConfirmation != nil || p.failed != nil {
		t.Fatalf("action terminal: %+v", p)
	}
	if p.controls[0][0].field.Text() != "unsaved draft" || loader.saves != 0 {
		t.Fatal("action changed or saved an editor draft")
	}
}

func TestSettingsActionCancellationAndPageCloseCannotPublishLateSuccess(t *testing.T) {
	for _, closed := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancel", true: "page-close"}[closed], func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			loader := &actionFormLoader{calls: make(chan bool, 1), blocked: true}
			wake := make(chan struct{}, 1)
			p := newPluginSettingsForm(loader, func() { wake <- struct{}{} })
			p.loaded = true
			t.Cleanup(func() {
				p.close()
				if p.running {
					select {
					case <-wake:
						p.drain()
					case <-time.After(5 * time.Second):
						t.Error("cancelled action worker did not terminate")
					}
				}
			})
			p.act("refresh", true)
			select {
			case <-loader.calls:
			case <-ctx.Done():
				t.Fatal("action did not start")
			}
			if closed {
				p.close()
			} else {
				p.cancel()
			}
			select {
			case <-wake:
				p.drain()
			case <-ctx.Done():
				t.Fatal("cancelled action worker remained alive")
			}
			if p.running || p.actionComplete || p.failed != nil {
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
