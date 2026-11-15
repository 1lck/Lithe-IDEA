package i18n

import "strconv"

// statusIndentSpaces is the indentation item when Tab inserts spaces, for example "4 spaces".
func statusIndentSpaces(language Language, count int) string {
	return SharedFormat(language, "desktop.status.indentSpaces", map[string]string{"count": strconv.Itoa(count)})
}

// statusIndentTab is the indentation item when Tab inserts a tab, showing the tab width.
func statusIndentTab(language Language, width int) string {
	return SharedFormat(language, "desktop.status.indentTab", map[string]string{"width": strconv.Itoa(width)})
}
