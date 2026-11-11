package i18n

// DebugBreakpointMessages are the words of the breakpoint editor: the condition,
// hit count and log message a source breakpoint may carry.
type DebugBreakpointMessages struct {
	Edit                    string
	Title                   func(file, line string) string
	Condition               string
	ConditionPlaceholder    string
	HitCondition            string
	HitConditionPlaceholder string
	LogMessage              string
	LogMessagePlaceholder   string
	Save                    string
	Cancel                  string
	// Conditional and LogPoint mark a breakpoint row that carries the option.
	Conditional string
	LogPoint    string
}

func debugBreakpointMessages(language Language) DebugBreakpointMessages {
	return DebugBreakpointMessages{
		Edit: Shared(language, "desktop.debug.breakpoint.edit"),
		Title: func(file, line string) string {
			return SharedFormat(language, "desktop.debug.breakpoint.title", map[string]string{"file": file, "line": line})
		},
		Condition:               Shared(language, "desktop.debug.breakpoint.condition"),
		ConditionPlaceholder:    Shared(language, "desktop.debug.breakpoint.conditionPlaceholder"),
		HitCondition:            Shared(language, "desktop.debug.breakpoint.hitCondition"),
		HitConditionPlaceholder: Shared(language, "desktop.debug.breakpoint.hitConditionPlaceholder"),
		LogMessage:              Shared(language, "desktop.debug.breakpoint.logMessage"),
		LogMessagePlaceholder:   Shared(language, "desktop.debug.breakpoint.logMessagePlaceholder"),
		Save:                    Shared(language, "ui.save"),
		Cancel:                  Shared(language, "desktop.git.cancel"),
		Conditional:             Shared(language, "desktop.debug.breakpoint.conditional"),
		LogPoint:                Shared(language, "desktop.debug.breakpoint.logPoint"),
	}
}
