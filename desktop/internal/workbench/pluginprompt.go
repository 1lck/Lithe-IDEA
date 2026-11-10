package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/1lck/Lithe-IDEA/desktop/internal/sheet"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// A plugin may ask the user something: a message with up to three actions, or the
// consent to run a program in a terminal. Both are one modal sheet over the
// workbench, shown one at a time in the order they arrived. The user's choice, a
// dismissal, the request's cancellation or the project closing ends a prompt.
//
// The sheet is drawn with the window's Frame engine, like the plugin review sheet
// beside it, because the window around it is not on Viva Pages yet.

var (
	pluginPromptScope   = tree.ID(shellPage, "plugin-prompt-scope")
	pluginPromptDismiss = tree.ID(shellPage, "plugin-prompt-dismiss")
	pluginPromptScroll  = tree.ID(shellPage, "plugin-prompt-scroll")
	// pluginPromptAction.At(i) is the i-th action button.
	pluginPromptAction = tree.Sub(shellPage, tree.Name("plugin-prompt-action"))
)

// pluginPrompt is one question to the user.
type pluginPrompt struct {
	title string
	text  string
	// mono shows the text in a fixed-pitch font, for commands and paths.
	mono    bool
	actions []string
	// answer receives the chosen index, or nil for a dismissal. It is buffered, so
	// answering never blocks the window.
	answer chan *int
}

// pluginPrompts is the queue of questions.
type pluginPrompts struct {
	queue []*pluginPrompt
}

// askUser queues a prompt and waits for the answer. A cancelled request removes
// its prompt, so the user is never asked something nobody is waiting for.
func (a *App) askUser(ctx context.Context, prompt *pluginPrompt) (*int, error) {
	prompt.answer = make(chan *int, 1)
	_, err := onWindow(a, ctx, func(a *App) (struct{}, error) {
		a.prompts.queue = append(a.prompts.queue, prompt)
		return struct{}{}, nil
	})
	if err != nil {
		return nil, err
	}
	select {
	case choice := <-prompt.answer:
		return choice, nil
	case <-ctx.Done():
		a.post(func(a *App) { a.dropPrompt(prompt) })
		return nil, ctx.Err()
	}
}

func (a *App) dropPrompt(prompt *pluginPrompt) {
	for i, queued := range a.prompts.queue {
		if queued == prompt {
			a.prompts.queue = append(a.prompts.queue[:i], a.prompts.queue[i+1:]...)
			return
		}
	}
}

// answerPrompt ends the first prompt with a choice.
func (a *App) answerPrompt(choice *int) {
	if len(a.prompts.queue) == 0 {
		return
	}
	prompt := a.prompts.queue[0]
	a.prompts.queue = a.prompts.queue[1:]
	prompt.answer <- choice
}

// cancelPrompts dismisses every waiting prompt, for a closing project.
func (a *App) cancelPrompts() {
	for len(a.prompts.queue) > 0 {
		a.answerPrompt(nil)
	}
}

func (w pluginWorkbench) Prompt(ctx context.Context, request pluginservice.PromptRequest) (*int, error) {
	language := w.app.language()
	title := i18n.SharedFormat(language, "desktop.pluginHost.messageFrom", map[string]string{"plugin": request.PluginID})
	actions := request.Actions
	if len(actions) == 0 {
		actions = []string{i18n.Shared(language, "desktop.pluginHost.messageOK")}
	}
	selected, err := w.app.askUser(ctx, &pluginPrompt{title: title, text: request.Text, actions: actions})
	if err != nil || selected == nil {
		return nil, err
	}
	if len(request.Actions) == 0 {
		// The default button only closes the message; the plugin asked for no choice.
		return nil, nil
	}
	return selected, nil
}

// drawPluginPrompt paints the first waiting prompt.
func (a *App) drawPluginPrompt(f *ui.Frame) {
	if len(a.prompts.queue) == 0 {
		return
	}
	prompt := a.prompts.queue[0]
	language := a.language()
	background := gfx.RGB24(0xF7F8FA)
	if a.colors.Dark {
		background = gfx.RGB24(0x242529)
	}
	chosen := -1
	dismissed := sheet.Draw(f, sheet.Options{Width: 520, Height: 320, Background: background,
		Scope: pluginPromptScope, Dismiss: pluginPromptDismiss, InitialFocus: pluginPromptAction.At(len(prompt.actions) - 1),
		DismissLabel: i18n.Shared(language, "desktop.pluginHost.messageDismiss")}, func() {
		f.Column().Fill().Pad(24).Gap(12).Children(func() {
			f.Text(prompt.title).FontSize(15).Weight(gfx.WeightBold).Color(a.colors.Text).Ellipsis()
			f.ScrollArea(pluginPromptScroll).Grow(1).FillWidth().Children(func() {
				text := f.Wrap(prompt.text).FontSize(13).Color(a.colors.Text)
				if prompt.mono {
					text.Mono()
				}
			})
			f.Row().FillWidth().Gap(8).Items(ui.Center).Children(func() {
				f.Spacer()
				for i, action := range prompt.actions {
					button := f.Button(pluginPromptAction.At(i), action)
					if i < len(prompt.actions)-1 {
						button.Outline()
					}
					if button.Clicked() {
						chosen = i
					}
				}
			})
		})
	})
	switch {
	case chosen >= 0:
		a.answerPrompt(&chosen)
	case dismissed:
		a.answerPrompt(nil)
	}
}
