package localshell

import (
	"path/filepath"
	"strings"
)

// Choice is an installed interactive shell. Default identifies the executable
// Start uses when Config.Shell is empty.
type Choice struct {
	Name, Path string
	Default    bool
}

type shellCandidate struct {
	name  string
	paths []string
}

// Each family contributes its first available executable, so PATH aliases and
// standard installation paths do not produce duplicate menu entries.
func discoverShells(candidates []shellCandidate, preferred string, lookup func(string) (string, error)) []Choice {
	var choices []Choice
	for _, candidate := range candidates {
		for _, program := range candidate.paths {
			if program == "" {
				continue
			}
			path, err := lookup(program)
			if err != nil {
				continue
			}
			path, err = filepath.Abs(path)
			if err != nil {
				continue
			}
			duplicate := false
			for _, choice := range choices {
				if strings.EqualFold(choice.Path, path) {
					duplicate = true
					break
				}
			}
			if !duplicate {
				choices = append(choices, Choice{Name: candidate.name, Path: path, Default: strings.EqualFold(filepath.Clean(preferred), path)})
			}
			break
		}
	}
	return choices
}

// DefaultShell is the program Start runs when Config.Shell is empty: the user's login
// shell on Unix ($SHELL, else /bin/sh) and PowerShell, else the command processor, on
// Windows. Settings show it as what "automatic" resolves to.
func DefaultShell() string {
	return defaultShell()
}

// Labels names each choice for a menu or a picker. A name that only one choice has stands
// alone; choices that share a name are told apart by withPath, which shows the name and the
// path, so two installations of bash read "bash (/bin/bash)" and
// "bash (/opt/homebrew/bin/bash)" beside a single "zsh".
func Labels(choices []Choice, withPath func(name, path string) string) []string {
	count := make(map[string]int, len(choices))
	for _, choice := range choices {
		count[choice.Name]++
	}
	labels := make([]string, len(choices))
	for i, choice := range choices {
		if count[choice.Name] > 1 {
			labels[i] = withPath(choice.Name, choice.Path)
		} else {
			labels[i] = choice.Name
		}
	}
	return labels
}
