package workbench

import (
	"context"
	"runtime"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/encodingname"
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/1lck/Lithe-IDEA/desktop/internal/settingswindow"
)

// outputEncodingPolicy snapshots the application preference for a new console. Process
// observers may call it off the window thread, so it never reads mutable settings.
func (a *App) outputEncodingPolicy() core.OutputEncodingPolicy {
	policy := core.OutputEncodingPolicy{Windows: runtime.GOOS == "windows"}
	if setting := a.consoleEncoding.Load(); setting != nil {
		policy.Setting = *setting
	}
	return policy
}

func (a *App) setConsoleEncoding(value string) {
	a.settings.ConsoleEncoding = value
	a.consoleEncoding.Store(&value)
	a.saveSettings()
}

// refreshConsoleEncodings reads the catalog and automatic candidates from the same Core
// resolver used by decoding. The immutable snapshot can be read from the settings thread.
func (a *App) refreshConsoleEncodings() {
	if a.kernel == nil {
		return
	}
	policy := core.OutputEncodingPolicy{Windows: runtime.GOOS == "windows"}
	a.background(nil, outputDecodeTimeout, func(ctx context.Context) func(*App) {
		resolved, err := a.kernel.ResolveOutputEncoding(ctx, policy)
		return func(a *App) {
			view := settingswindow.ConsoleEncodings{}
			if err != nil {
				a.backgroundFailed("console_encodings", err)
				view.Error = i18n.Shared(a.language(), "desktop.consoleSettings.readFailed")
			} else {
				for _, id := range resolved.Candidates {
					view.Automatic = append(view.Automatic, settingswindow.ConsoleEncoding{ID: id, Label: encodingname.DisplayName(id)})
				}
				for _, id := range resolved.Encodings {
					view.Choices = append(view.Choices, settingswindow.ConsoleEncoding{ID: id, Label: encodingname.DisplayName(id)})
				}
			}
			a.consoleEncodings.Store(&view)
			if a.settingsWindow != nil {
				a.settingsWindow.Invalidate()
			}
		}
	})
}

func (a *App) consoleEncodingsOption() (settingswindow.ConsoleEncodings, bool) {
	if resolved := a.consoleEncodings.Load(); resolved != nil {
		return *resolved, true
	}
	return settingswindow.ConsoleEncodings{}, false
}
