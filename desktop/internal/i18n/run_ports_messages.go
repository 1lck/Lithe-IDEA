package i18n

import "strconv"

// RunPortsMessages are the labels and menu items of a running process tree's listening ports.
type RunPortsMessages struct {
	Label      string
	Open       string
	Copy       string
	More       func(count int) string
	OpenFailed func(url string) string
}

func runPortsMessages(language Language) RunPortsMessages {
	return RunPortsMessages{
		Label: Shared(language, "desktop.run.ports.label"),
		Open:  Shared(language, "desktop.run.ports.open"),
		Copy:  Shared(language, "desktop.run.ports.copy"),
		More: func(count int) string {
			return SharedFormat(language, "desktop.run.ports.more", map[string]string{"count": strconv.Itoa(count)})
		},
		OpenFailed: func(url string) string {
			return SharedFormat(language, "desktop.run.ports.openFailed", map[string]string{"url": url})
		},
	}
}
