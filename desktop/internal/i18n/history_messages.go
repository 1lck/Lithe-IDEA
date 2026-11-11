package i18n

// HistoryMessages are the words of the Local History dialog.
type HistoryMessages struct {
	Show, Title, Loading, Empty, Restore, Delete, Rename string
	LabelPlaceholder, Close, PreviewLoading              string
	// CompareWithCurrent and CompareWithPrevious open the Diff of the selected snapshot
	// against the current text or against the snapshot before it; CurrentVersion names the
	// current text as a side of that Diff, and NoChanges says the two sides are the same.
	CompareWithCurrent, CompareWithPrevious, CurrentVersion, NoChanges string
	Failed                                                             func(reason string) string
	// Reason names the event that took a snapshot.
	Reason func(reason string) string
}

func historyMessages(language Language) HistoryMessages {
	reasons := map[string]string{
		"projectBaseline":    Shared(language, "desktop.history.reasonBaseline"),
		"saved":              Shared(language, "desktop.history.reasonSaved"),
		"restored":           Shared(language, "desktop.history.reasonRestored"),
		"externalChange":     Shared(language, "desktop.history.reasonExternalChange"),
		"beforeRename":       Shared(language, "desktop.history.reasonBeforeRename"),
		"beforeDelete":       Shared(language, "desktop.history.reasonBeforeDelete"),
		"beforeBatchReplace": Shared(language, "desktop.history.reasonBatchReplace"),
		"unsavedDiscard":     Shared(language, "desktop.history.reasonUnsavedDiscard"),
	}
	return HistoryMessages{
		Show:                Shared(language, "desktop.history.show"),
		Title:               Shared(language, "desktop.history.title"),
		Loading:             Shared(language, "desktop.history.loading"),
		Empty:               Shared(language, "desktop.history.empty"),
		Restore:             Shared(language, "desktop.history.restore"),
		Delete:              Shared(language, "desktop.history.delete"),
		Rename:              Shared(language, "desktop.history.rename"),
		LabelPlaceholder:    Shared(language, "desktop.history.labelPlaceholder"),
		Close:               Shared(language, "desktop.history.close"),
		PreviewLoading:      Shared(language, "desktop.history.previewLoading"),
		CompareWithCurrent:  Shared(language, "localHistory.compareWithCurrent"),
		CompareWithPrevious: Shared(language, "localHistory.compareWithPrevious"),
		CurrentVersion:      Shared(language, "native.currentVersion"),
		NoChanges:           Shared(language, "localHistory.noChangesToCompare"),
		Failed: func(reason string) string {
			return SharedFormat(language, "desktop.history.failed", map[string]string{"reason": reason})
		},
		Reason: func(reason string) string {
			if text, ok := reasons[reason]; ok {
				return text
			}
			return reason
		},
	}
}
