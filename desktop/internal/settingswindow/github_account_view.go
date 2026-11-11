package settingswindow

import (
	"github.com/1lck/Lithe-IDEA/desktop/internal/i18n"
	"github.com/vivaui/viva/gfx"
	"github.com/vivaui/viva/ui"
)

// GitHubAccount is the GitHub account the Version Control page shows. The window reads a snapshot
// on every paint and asks the owner to act; the owner keeps the token and the sign-in.
type GitHubAccount struct {
	// Snapshot reads the account; it must not block.
	Snapshot func() GitHubState
	// SignIn starts the device authorization; Cancel stops one; SignOut forgets the account.
	SignIn  func()
	Cancel  func()
	SignOut func()
}

// GitHubState is what the card shows: whether sign-in is configured, whether an account is
// connected and as whom, and the device authorization in progress with its user code.
type GitHubState struct {
	Available       bool
	Connected       bool
	Login           string
	Starting        bool
	Waiting         bool
	Validating      bool
	UserCode        string
	VerificationURI string
	Error           string
}

// gitHubCard declares the GitHub account card: the account or the sign-in in progress, with the
// button that signs in, cancels, or signs out.
func (w *window) gitHubCard(c ui.C, language i18n.Language, account *GitHubAccount) {
	state := GitHubState{}
	if account.Snapshot != nil {
		state = account.Snapshot()
	}
	title := i18n.Shared(language, "desktop.github.settingsTitle")
	help := i18n.Shared(language, "desktop.github.settingsHelp")
	w.card(c, title, help, func() {
		ui.Column(c).FillWidth().Gap(6).Children(func() {
			switch {
			case state.Connected:
				ui.Text(c, i18n.SharedFormat(language, "desktop.github.connectedAs", map[string]string{"login": state.Login}))
				if ui.Button(c, i18n.Shared(language, "desktop.github.signOut")).Outline().Clicked() && account.SignOut != nil {
					account.SignOut()
				}
			case state.Waiting:
				ui.Text(c, i18n.Shared(language, "desktop.github.enterCode"))
				ui.Text(c, state.UserCode).Weight(gfx.WeightSemibold)
				ui.Text(c, state.VerificationURI).Color(w.pal.muted)
				if ui.Button(c, i18n.Shared(language, "desktop.github.cancelSignIn")).Outline().Clicked() && account.Cancel != nil {
					account.Cancel()
				}
			case state.Starting, state.Validating:
				ui.Text(c, i18n.Shared(language, "desktop.github.working"))
			default:
				if !state.Available {
					ui.Text(c, i18n.Shared(language, "desktop.github.notConfigured")).Color(w.pal.muted)
				} else if ui.Button(c, i18n.Shared(language, "desktop.github.signIn")).Outline().Clicked() && account.SignIn != nil {
					account.SignIn()
				}
			}
			if state.Error != "" {
				ui.Paragraph(c, state.Error, 3).Color(w.pal.danger)
			}
		})
	})
}
