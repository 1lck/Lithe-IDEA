package i18n

// SearchMessages are the words of Find and Replace in Files beyond the shared
// search labels.
type SearchMessages struct {
	Replace, ReplacePlaceholder, ReplaceAll, ReplaceToggle string
	PreviewTitle, Previewing, NoReplacements, Cancel       string
	ReplaceConflict                                        string
	ReplaceSummary                                         func(occurrences, files string) string
	ReplaceFailed                                          func(reason string) string
	ReplaceDone                                            func(files string) string
	ReplaceSkipped                                         func(changed, skipped string) string
	ReplacePartlyFailed                                    func(changed, failed, reason string) string
}

func searchMessages(language Language) SearchMessages {
	return SearchMessages{
		Replace:            Shared(language, "desktop.search.replace"),
		ReplacePlaceholder: Shared(language, "desktop.search.replacePlaceholder"),
		ReplaceAll:         Shared(language, "desktop.search.replaceAll"),
		ReplaceToggle:      Shared(language, "desktop.search.replaceToggle"),
		PreviewTitle:       Shared(language, "desktop.search.replacePreviewTitle"),
		Previewing:         Shared(language, "desktop.search.replacePreviewing"),
		NoReplacements:     Shared(language, "desktop.search.noReplacements"),
		Cancel:             Shared(language, "desktop.git.cancel"),
		ReplaceConflict:    Shared(language, "desktop.search.replaceConflict"),
		ReplaceSummary: func(occurrences, files string) string {
			return SharedFormat(language, "desktop.search.replaceSummary", map[string]string{"occurrences": occurrences, "files": files})
		},
		ReplaceFailed: func(reason string) string {
			return SharedFormat(language, "desktop.search.replaceFailed", map[string]string{"reason": reason})
		},
		ReplaceDone: func(files string) string {
			return SharedFormat(language, "desktop.search.replaceDone", map[string]string{"files": files})
		},
		ReplaceSkipped: func(changed, skipped string) string {
			return SharedFormat(language, "desktop.search.replaceSkipped", map[string]string{"changed": changed, "skipped": skipped})
		},
		ReplacePartlyFailed: func(changed, failed, reason string) string {
			return SharedFormat(language, "desktop.search.replacePartlyFailed", map[string]string{"changed": changed, "failed": failed, "reason": reason})
		},
	}
}
