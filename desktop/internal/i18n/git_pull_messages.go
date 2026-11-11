package i18n

// PullMessages are the words of the Pull dialog of the log tab: which repository, remote and
// remote branch to pull, and how to combine a diverged history.
type PullMessages struct {
	MenuItem     string
	Title        string
	Prompt       string
	Repository   string
	Remote       string
	RemoteBranch string
	Strategy     string
	Merge        string
	Rebase       string
	FastForward  string
	Button       string
	Loading      string
	NoRemote     string
	NoBranch     string
	ReadFailed   func(reason string) string
}

func pullMessages(language Language) PullMessages {
	return PullMessages{
		MenuItem:     Shared(language, "desktop.pull.menu"),
		Title:        Shared(language, "desktop.pull.title"),
		Prompt:       Shared(language, "desktop.pull.prompt"),
		Repository:   Shared(language, "desktop.pull.repository"),
		Remote:       Shared(language, "desktop.pull.remote"),
		RemoteBranch: Shared(language, "desktop.pull.remoteBranch"),
		Strategy:     Shared(language, "desktop.pull.strategy"),
		Merge:        Shared(language, "desktop.pull.merge"),
		Rebase:       Shared(language, "desktop.pull.rebase"),
		FastForward:  Shared(language, "desktop.pull.fastForward"),
		Button:       Shared(language, "desktop.pull.button"),
		Loading:      Shared(language, "desktop.pull.loading"),
		NoRemote:     Shared(language, "desktop.pull.noRemote"),
		NoBranch:     Shared(language, "desktop.pull.noBranch"),
		ReadFailed: func(reason string) string {
			return SharedFormat(language, "desktop.pull.readFailed", map[string]string{"reason": reason})
		},
	}
}
