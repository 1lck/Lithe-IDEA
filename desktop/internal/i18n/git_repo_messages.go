package i18n

import "strconv"

// GitRepositoryMessages label the repository the Git log walks: the header of the commit list names
// it, or counts the repositories it walks together, lists the repositories to walk on a click, and
// offers the way back to the project's own repository while a nested one is walked.
type GitRepositoryMessages struct {
	Current func(name string) string
	Back    func(name string) string
	Several func(count int) string
	Choose  string
}

func gitRepositoryMessages(language Language) GitRepositoryMessages {
	return GitRepositoryMessages{
		Current: func(name string) string {
			return SharedFormat(language, "desktop.git.repo.current", map[string]string{"name": name})
		},
		Back: func(name string) string {
			return SharedFormat(language, "desktop.git.repo.back", map[string]string{"name": name})
		},
		Several: func(count int) string {
			return SharedFormat(language, "desktop.git.repo.several", map[string]string{"count": strconv.Itoa(count)})
		},
		Choose: Shared(language, "desktop.git.repo.choose"),
	}
}
