package workbench

import (
	"context"
	"testing"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/plugininstall"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/gfx"
)

// askInBackground asks a plugin prompt from another goroutine, as a plugin host
// call does, and waits until the window has queued it and painted its dialog.
func askInBackground(t *testing.T, h *harness, request pluginservice.PromptRequest) <-chan *int {
	t.Helper()
	answers := make(chan *int, 1)
	w := pluginWorkbench{app: h.app}
	go func() {
		choice, _ := w.Prompt(context.Background(), request)
		answers <- choice
	}()
	h.await("the prompt queued", func() bool { return len(h.app.prompts.queue) > 0 })
	h.settle()
	return answers
}

func TestPluginPromptButtonsAnswerWithTheirIndex(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	answers := askInBackground(t, h, pluginservice.PromptRequest{PluginID: "p", Text: "go?", Actions: []string{"No", "Yes"}})
	if got := h.focusedName(); got != "Yes" {
		t.Fatalf("the prompt focused %q, want its last action", got)
	}
	h.clickNamed("Yes")
	if choice := <-answers; choice == nil || *choice != 1 {
		t.Fatalf("answer = %v, want the second action", choice)
	}
	h.settle()
	if len(h.app.prompts.queue) != 0 || h.overlayOpen() {
		t.Fatal("the answered prompt stayed on screen")
	}
}

func TestPluginPromptEscapeDismissesIt(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	answers := askInBackground(t, h, pluginservice.PromptRequest{PluginID: "p", Text: "go?", Actions: []string{"No", "Yes"}})
	if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
		t.Fatal(err)
	}
	if choice := <-answers; choice != nil {
		t.Fatalf("a dismissed prompt answered %d", *choice)
	}
}

func TestPluginReviewCancelAndEscapeDiscardTheInstall(t *testing.T) {
	for _, dismiss := range []string{"button", "escape"} {
		t.Run(dismiss, func(t *testing.T) {
			h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
			h.app.pluginInstall.generation = 1
			h.app.pluginInstall.busy = true
			h.app.finishPluginInstall(1, plugininstall.Plan{ID: "example", Version: "1.0.0"}, nil)
			h.app.invalidator.Invalidate()
			h.settle()
			if !h.overlayOpen() {
				t.Fatal("the review is not on screen")
			}
			if dismiss == "button" {
				h.clickShared("desktop.marketplace.cancel")
			} else if err := h.driver.Key(gfx.KeyEscape, 0); err != nil {
				t.Fatal(err)
			}
			if h.app.pluginInstall.open || h.app.pluginInstall.plan.Version != "" {
				t.Fatalf("the install was not discarded: %+v", h.app.pluginInstall)
			}
		})
	}
}

func TestNoticeIsShownAsAToast(t *testing.T) {
	h := newHarnessWithLanguages(t, &testKernel{Client: core.NewClient()}, []string{"en-US"})
	h.app.notify("Something to know")
	h.app.invalidator.Invalidate()
	h.settle()
	if !h.shows("Something to know") {
		t.Fatal("the notice is not on screen")
	}
}

// overlayOpen reports whether a dialog of the overlay page holds the window.
func (h *harness) overlayOpen() bool {
	return h.app.pluginInstall.open || len(h.app.prompts.queue) > 0 || h.app.clone.open
}
