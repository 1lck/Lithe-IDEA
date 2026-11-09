// Package i18n holds every string the desktop client shows, as one typed Go catalog per
// language. A screen reads its words from the Messages of the current language
// (i18n.For(language).Welcome.Open), so a missing translation is a compile error or a
// test failure, never a key printed on screen. Words that take a value are functions in
// the catalog, so word order stays the translator's choice.
//
// Diagnostics from the core, Git output and user content are not translated here: they
// are shown as they arrive.
package i18n

import "strings"

// Language is a language the client is translated into.
type Language uint8

const (
	// English is the fallback when the system prefers no language the client has.
	English Language = iota
	// Chinese is Simplified Chinese.
	Chinese
)

// Languages lists the supported languages in the order the settings offer them.
var Languages = [...]Language{Chinese, English}

// Code is the stable name a language is stored under.
func (language Language) Code() string {
	if language == Chinese {
		return "zh-Hans"
	}
	return "en"
}

// Native is the language's name written in that language, the way a language picker
// shows it whatever the current language is.
func (language Language) Native() string {
	if language == Chinese {
		return "简体中文"
	}
	return "English"
}

// Parse reads a stored Code back; ok is false for an empty or unknown code.
func Parse(code string) (language Language, ok bool) {
	switch code {
	case "zh-Hans":
		return Chinese, true
	case "en":
		return English, true
	}
	return English, false
}

// Detect picks the first supported language from the system's preferred list (BCP 47
// tags such as "zh-Hans-CN" or "en-US"), English when none is supported.
func Detect(preferred []string) Language {
	for _, tag := range preferred {
		tag = strings.ToLower(tag)
		switch {
		case tag == "zh" || strings.HasPrefix(tag, "zh-"):
			return Chinese
		case tag == "en" || strings.HasPrefix(tag, "en-"):
			return English
		}
	}
	return English
}

// For returns the catalog of a language. The catalogs are package values that never
// change, so the pointer may be kept for as long as the language is current.
func For(language Language) *Messages {
	if language == Chinese {
		return &chinese
	}
	return &english
}

// Shared resolves a key generated from shared/i18n for the current language.
func Shared(language Language, key string) string {
	return lookupShared(language, key)
}

func lookupShared(language Language, key string) string {
	locale := "en-US"
	if language == Chinese {
		locale = "zh-CN"
	}
	if value, ok := sharedCatalogs[locale][key]; ok {
		return value
	}
	return sharedCatalogs["en-US"][key]
}

// SharedFormat substitutes arguments in a generated shared template in one pass.
// A value containing a placeholder is inserted literally, not interpreted again.
func SharedFormat(language Language, key string, arguments map[string]string) string {
	return formatSharedTemplate(lookupShared(language, key), arguments)
}

func formatSharedTemplate(value string, arguments map[string]string) string {
	if len(arguments) == 0 {
		return value
	}
	if len(arguments) == 1 {
		for name, argument := range arguments {
			return strings.ReplaceAll(value, "{"+name+"}", argument)
		}
	}
	pairs := make([]string, 0, len(arguments)*2)
	for name, argument := range arguments {
		pairs = append(pairs, "{"+name+"}", argument)
	}
	return strings.NewReplacer(pairs...).Replace(value)
}
