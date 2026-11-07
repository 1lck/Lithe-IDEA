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
