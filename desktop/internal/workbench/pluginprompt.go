package workbench

import (
	"context"

	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
	"github.com/vivaui/viva/ui"
)

// A plugin may ask the user something: a message with up to three actions, or the
// consent to run a program in a terminal. Both are one modal sheet over the
// workbench, shown one at a time in the order they arrived. The user's choice, a
// dismissal, the request's cancellation or the project closing ends a prompt.

// pluginPrompt is one question to the user.
type pluginPrompt struct {
	title string
	text  string
	// mono shows the text in a fixed-pitch font, for commands and paths.
	mono    bool
	actions []string
	// check, when set, is the label of a checkbox under the text, such as "Don't ask
	// again"; checked is its state, which onAnswer reads.
	check   string
	checked bool
	// open is the flag the modal that shows the prompt keeps.
	open bool
	// answer receives the chosen index, or nil for a dismissal. It is buffered, so
	// answering never blocks the window.
	answer chan *int
	// onAnswer, when set, is called on the window thread instead of sending to
	// answer: a question the window itself asks has nobody waiting on a channel.
	onAnswer func(choice *int)
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
	if prompt.onAnswer != nil {
		prompt.onAnswer(choice)
		return
	}
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

// pluginPromptView declares the first waiting prompt.
func (a *App) pluginPromptView(c ui.C) {
	if len(a.prompts.queue) == 0 {
		return
	}
	prompt := a.prompts.queue[0]
	chosen := -1
	// The modal is named by the prompt's own open flag, so a following prompt
	// is a new dialog; it is raised again for each paint the prompt is first.
	prompt.open = true
	dismissed := ui.ModalWith(c, &prompt.open, prompt.title, ui.ModalSpec{Width: 520, Height: 320}, func() {
		ui.Scroll(c).Grow(1).FillWidth().Children(func() {
			text := ui.Wrap(c, prompt.text).FontSize(13)
			if prompt.mono {
				text.Mono()
			}
		})
		if prompt.check != "" {
			ui.Checkbox(c.Part("check"), &prompt.checked, prompt.check)
		}
	}, func() {
		for i, action := range prompt.actions {
			button := ui.Button(c.KeyInt(i), action)
			if i < len(prompt.actions)-1 {
				button.Outline()
			} else {
				button.AutoFocus()
			}
			if button.Clicked() {
				chosen = i
			}
		}
	})
	switch {
	case chosen >= 0:
		c.After(func() { a.answerPrompt(&chosen) })
	case dismissed:
		c.After(func() { a.answerPrompt(nil) })
	}
}
