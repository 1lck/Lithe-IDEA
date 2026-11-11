package pluginservice

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

const (
	// commandLineLimit is the longest command line the host hands to the operating
	// system, with headroom for the terminating null and host quoting. Windows
	// refuses a CreateProcess command line of 32,767 UTF-16 code units; the UTF-8
	// length of a line is never shorter than its UTF-16 length, so the byte count is a
	// safe estimate.
	commandLineLimit = 32767 - 2048
	// argumentFileName names the argument file a shortened launch reads.
	argumentFileName = "launch.args"
)

// javaPathOptions are the options whose value is a list of paths. They carry nearly all
// of an oversized Java command line, so moving them to an argument file leaves the JVM
// options and the program arguments where they were.
var javaPathOptions = map[string]bool{"-cp": true, "-classpath": true, "--class-path": true, "-p": true, "--module-path": true}

// argumentFilePlan is a JDK launch whose path-list options move to an argument file: the
// arguments with one placeholder where the file reference goes, and the file's text.
type argumentFilePlan struct {
	arguments   []string
	placeholder int
	contents    string
}

// planJavaArgumentFile moves the path-list options of a JDK launch into an argument file
// when the command line would exceed the limit. It returns false, and the caller starts the
// launch unchanged, for a launch that fits, a launcher that is not a JDK 9 or later, or
// non-ASCII paths on a JDK that reads argument files in the system code page (before JDK 18).
func planJavaArgumentFile(executable string, arguments []string) (argumentFilePlan, bool) {
	if !isJavaLauncher(executable) || commandLineSize(executable, arguments) <= commandLineLimit {
		return argumentFilePlan{}, false
	}
	version := javaFeatureVersion(executable)
	if version < 9 {
		return argumentFilePlan{}, false
	}
	var plan argumentFilePlan
	var body strings.Builder
	plan.placeholder = -1
	nonASCII := false
	move := func(option, value string) {
		if plan.placeholder < 0 {
			plan.placeholder = len(plan.arguments)
			plan.arguments = append(plan.arguments, "")
		}
		writeArgfileToken(&body, option)
		writeArgfileToken(&body, value)
		nonASCII = nonASCII || !isASCII(value)
	}
	for index := 0; index < len(arguments); index++ {
		argument := arguments[index]
		if javaPathOptions[argument] && index+1 < len(arguments) {
			move(argument, arguments[index+1])
			index++
			continue
		}
		// The --class-path=value spelling is one argument and moves the same way.
		if name, value, found := strings.Cut(argument, "="); found && javaPathOptions[name] {
			move(name, value)
			continue
		}
		plan.arguments = append(plan.arguments, argument)
	}
	if plan.placeholder < 0 || (nonASCII && version < 18) {
		return argumentFilePlan{}, false
	}
	plan.contents = body.String()
	return plan, true
}

// withFile returns the planned arguments with the argument file reference in place of
// the placeholder.
func (plan argumentFilePlan) withFile(path string) []string {
	result := append([]string(nil), plan.arguments...)
	result[plan.placeholder] = "@" + path
	return result
}

// writeArgfileToken quotes one token the way the JDK argument-file reader expects:
// double quotes, with backslashes and quotes escaped.
func writeArgfileToken(body *strings.Builder, token string) {
	body.WriteByte('"')
	for _, r := range token {
		if r == '\\' || r == '"' {
			body.WriteByte('\\')
		}
		body.WriteRune(r)
	}
	body.WriteString("\"\n")
}

// writeArgumentFile writes the argument file into directory, readable by the owner only.
func writeArgumentFile(directory, contents string) (string, error) {
	if directory == "" {
		return "", errors.New("the argument file has no directory")
	}
	path := filepath.Join(directory, argumentFileName)
	if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
		return "", err
	}
	return path, nil
}

// isJavaLauncher reports whether the executable is a java launcher by its file name.
func isJavaLauncher(executable string) bool {
	name := strings.ToLower(filepath.Base(executable))
	return name == "java" || name == "java.exe" || name == "javaw" || name == "javaw.exe"
}

// commandLineSize estimates the command line the arguments produce, with a quote and a
// separator around each.
func commandLineSize(executable string, arguments []string) int {
	size := len(executable) + 3
	for _, argument := range arguments {
		size += len(argument) + 3
	}
	return size
}

func isASCII(text string) bool {
	for index := 0; index < len(text); index++ {
		if text[index] >= 0x80 {
			return false
		}
	}
	return true
}

// javaFeatureVersion reads the JDK feature version from the release file of the JDK the
// launcher belongs to. It returns 0 when the file is absent or unreadable, which keeps the
// launch unchanged.
func javaFeatureVersion(executable string) int {
	home := filepath.Dir(filepath.Dir(executable))
	data, err := os.ReadFile(filepath.Join(home, "release"))
	if err != nil {
		return 0
	}
	for _, line := range strings.Split(string(data), "\n") {
		value, found := strings.CutPrefix(strings.TrimSpace(line), "JAVA_VERSION=")
		if !found {
			continue
		}
		parts := strings.FieldsFunc(strings.Trim(value, `"`), func(r rune) bool {
			return r == '.' || r == '_' || r == '-' || r == '+'
		})
		if len(parts) == 0 {
			return 0
		}
		first, err := strconv.Atoi(parts[0])
		if err != nil {
			return 0
		}
		if first == 1 && len(parts) > 1 {
			// Legacy "1.8.0_392" versions: the feature release is the second number.
			if second, err := strconv.Atoi(parts[1]); err == nil {
				return second
			}
			return 0
		}
		return first
	}
	return 0
}
