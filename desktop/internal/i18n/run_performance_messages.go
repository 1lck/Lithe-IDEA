package i18n

// RunPerformanceMessages label the CPU and memory readings drawn beside a run's output.
type RunPerformanceMessages struct {
	// CPU reports the latest CPU share, as a whole percentage text.
	CPU func(percent string) string
	// Memory reports the latest resident memory in megabytes.
	Memory func(megabytes string) string
}

func runPerformanceMessages(language Language) RunPerformanceMessages {
	return RunPerformanceMessages{
		CPU: func(percent string) string {
			return SharedFormat(language, "desktop.run.performance.cpu", map[string]string{"percent": percent})
		},
		Memory: func(megabytes string) string {
			return SharedFormat(language, "desktop.run.performance.memory", map[string]string{"megabytes": megabytes})
		},
	}
}
