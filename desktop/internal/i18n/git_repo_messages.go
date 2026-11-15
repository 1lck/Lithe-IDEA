package i18n

// GitRepositoryMessages label the repository the Git log walks: the header of the commit list names
// it, and offers the way back to the project's own repository while a nested one is walked.
type GitRepositoryMessages struct {
	Current func(name string) string
	Back    func(name string) string
}

func gitRepositoryMessages(language Language) GitRepositoryMessages {
	return GitRepositoryMessages{
		Current: func(name string) string {
			return SharedFormat(language, "desktop.git.repo.current", map[string]string{"name": name})
		},
		Back: func(name string) string {
			return SharedFormat(language, "desktop.git.repo.back", map[string]string{"name": name})
		},
	}
}
