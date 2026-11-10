package i18n

import "strconv"

// SyncMessages are the words of the Git operations that talk to a remote: fetch and the
// update of a branch.
type SyncMessages struct {
	Fetching  func() string
	Updating  func(name string) string
	Cancel    string
	Cancelled string

	Fetched      string
	FetchFailed  func(reason string) string
	UpdateFailed func(reason string) string
	Updated      func(name string) string
	Merged       func(name string) string
	Rebased      func(name string) string
	UpToDate     func(name string) string
	NoUpstream   func(name string) string
	// AuthFailed words a refused sign-in with what the user can do about it.
	AuthFailed func(reason string) string

	FetchTitle   string
	FetchPrompt  string
	AllRemotes   string
	RemoteName   string
	Prune        string
	Submodules   string
	Tags         string
	Inherit      string
	No           string
	OnDemand     string
	Yes          string
	TagsAll      string
	TagsNone     string
	TagsPrune    string
	FetchButton  string
	DivergeTitle string
	// DivergePrompt says how far the branch and its upstream have drifted apart.
	DivergePrompt func(name, upstream string, ahead, behind int) string
	Merge         string
	Rebase        string
}

func syncMessages(language Language) SyncMessages {
	return SyncMessages{
		Fetching: func() string { return Shared(language, "desktop.sync.fetching") },
		Updating: func(name string) string {
			return SharedFormat(language, "desktop.sync.updating", map[string]string{"name": name})
		},
		Cancel:    Shared(language, "desktop.sync.cancel"),
		Cancelled: Shared(language, "desktop.sync.cancelled"),
		Fetched:   Shared(language, "desktop.sync.fetched"),
		FetchFailed: func(reason string) string {
			return SharedFormat(language, "desktop.sync.fetchFailed", map[string]string{"reason": reason})
		},
		UpdateFailed: func(reason string) string {
			return SharedFormat(language, "desktop.sync.updateFailed", map[string]string{"reason": reason})
		},
		Updated: func(name string) string {
			return SharedFormat(language, "desktop.sync.updated", map[string]string{"name": name})
		},
		Merged: func(name string) string {
			return SharedFormat(language, "desktop.sync.merged", map[string]string{"name": name})
		},
		Rebased: func(name string) string {
			return SharedFormat(language, "desktop.sync.rebased", map[string]string{"name": name})
		},
		UpToDate: func(name string) string {
			return SharedFormat(language, "desktop.sync.upToDate", map[string]string{"name": name})
		},
		NoUpstream: func(name string) string {
			return SharedFormat(language, "desktop.sync.noUpstream", map[string]string{"name": name})
		},
		AuthFailed: func(reason string) string {
			return SharedFormat(language, "desktop.sync.authFailed", map[string]string{"reason": reason})
		},
		FetchTitle:   Shared(language, "desktop.sync.fetchTitle"),
		FetchPrompt:  Shared(language, "desktop.sync.fetchPrompt"),
		AllRemotes:   Shared(language, "desktop.sync.allRemotes"),
		RemoteName:   Shared(language, "desktop.sync.remoteName"),
		Prune:        Shared(language, "desktop.sync.prune"),
		Submodules:   Shared(language, "desktop.sync.submodules"),
		Tags:         Shared(language, "desktop.sync.tags"),
		Inherit:      Shared(language, "desktop.sync.inherit"),
		No:           Shared(language, "desktop.sync.no"),
		OnDemand:     Shared(language, "desktop.sync.onDemand"),
		Yes:          Shared(language, "desktop.sync.yes"),
		TagsAll:      Shared(language, "desktop.sync.tagsAll"),
		TagsNone:     Shared(language, "desktop.sync.tagsNone"),
		TagsPrune:    Shared(language, "desktop.sync.tagsPrune"),
		FetchButton:  Shared(language, "desktop.sync.fetchButton"),
		DivergeTitle: Shared(language, "desktop.sync.divergedTitle"),
		DivergePrompt: func(name, upstream string, ahead, behind int) string {
			return SharedFormat(language, "desktop.sync.divergedPrompt", map[string]string{
				"name": name, "upstream": upstream, "ahead": strconv.Itoa(ahead), "behind": strconv.Itoa(behind)})
		},
		Merge:  Shared(language, "desktop.sync.merge"),
		Rebase: Shared(language, "desktop.sync.rebase"),
	}
}
