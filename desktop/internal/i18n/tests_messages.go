package i18n

import "strconv"

// TestMessages are the Tests tool window's words.
type TestMessages struct {
	Run                string
	Rerun              string
	RunAll             string
	Stop               string
	Running            string
	Preparing          string
	Stopping           string
	Empty              string
	NoSystems          string
	Passed             string
	Failed             string
	ExitedWithError    string
	NoTestsMatched     string
	NoTestsFound       string
	TimedOut           string
	Cancelled          string
	OpenLocation       string
	ResultsUnavailable func(error string) string
	Summary            func(passed, failed, skipped int) string
}

func testMessages(language Language) TestMessages {
	return TestMessages{
		Run:             Shared(language, "desktop.tests.run"),
		Rerun:           Shared(language, "desktop.tests.rerun"),
		RunAll:          Shared(language, "native.runAllTests"),
		Stop:            Shared(language, "desktop.tests.stop"),
		Running:         Shared(language, "desktop.tests.running"),
		Preparing:       Shared(language, "desktop.tests.preparing"),
		Stopping:        Shared(language, "desktop.tests.stopping"),
		Empty:           Shared(language, "desktop.tests.empty"),
		NoSystems:       Shared(language, "desktop.tests.noSystems"),
		Passed:          Shared(language, "native.testsPassed"),
		Failed:          Shared(language, "native.testsFailed"),
		ExitedWithError: Shared(language, "desktop.tests.exitedWithError"),
		NoTestsMatched:  Shared(language, "desktop.tests.noTestsMatched"),
		NoTestsFound:    Shared(language, "desktop.tests.noTestsFound"),
		TimedOut:        Shared(language, "desktop.tests.timedOut"),
		Cancelled:       Shared(language, "desktop.tests.cancelled"),
		OpenLocation:    Shared(language, "desktop.tests.openLocation"),
		ResultsUnavailable: func(reason string) string {
			return SharedFormat(language, "desktop.tests.resultsUnavailable", map[string]string{"error": reason})
		},
		Summary: func(passed, failed, skipped int) string {
			return SharedFormat(language, "desktop.tests.summary", map[string]string{
				"passed":  strconv.Itoa(passed),
				"failed":  strconv.Itoa(failed),
				"skipped": strconv.Itoa(skipped),
			})
		},
	}
}
