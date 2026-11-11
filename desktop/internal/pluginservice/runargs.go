package pluginservice

import (
	"context"
	"errors"
	"os"
	"path/filepath"

	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// A launch whose command line would overflow the operating system's limit starts with its
// path-list options in a JDK argument file. Core decides (execution.planLaunchCommand):
// whether the launcher is a JDK that reads argument files, what moves, and the file's text.
// The host reads the JDK's release files for it, encodes the text as the launcher reads it
// (argfile_encoding_*.go) and owns the file.

// argumentFileName names the argument file a shortened launch reads.
const argumentFileName = "launch.args"

// launchPlanner is the part of Core the run launch uses.
type launchPlanner interface {
	PlanLaunchCommand(ctx context.Context, request core.LaunchCommandRequest) (core.LaunchCommandPlan, error)
}

// planLaunch asks Core to fit a launch to the command line. A plan without an argument file
// starts the launch as it is.
func planLaunch(ctx context.Context, kernel launchPlanner, executable string, arguments []string) (core.LaunchCommandPlan, error) {
	return kernel.PlanLaunchCommand(ctx, core.LaunchCommandRequest{
		Executable:          executable,
		Arguments:           append([]string{}, arguments...),
		JavaReleaseContents: javaReleaseContents(executable),
	})
}

// javaReleaseContents reads the release files of the JDK the executable may belong to,
// nearest first: the one beside its bin directory, then the one above it (a JDK 8 jre/bin
// launcher). A link to the launcher is followed first. Unreadable files are left out.
func javaReleaseContents(executable string) []string {
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	home := filepath.Dir(filepath.Dir(executable))
	var contents []string
	for _, directory := range []string{home, filepath.Dir(home)} {
		if data, err := os.ReadFile(filepath.Join(directory, "release")); err == nil {
			contents = append(contents, string(data))
		}
	}
	return contents
}

// launchArguments writes the plan's argument file into directory and returns the arguments
// that read it; a plan without one returns its arguments.
func launchArguments(plan core.LaunchCommandPlan, directory string) ([]string, error) {
	file := plan.ArgumentFile
	if file == nil {
		return plan.Arguments, nil
	}
	if file.ArgumentIndex < 0 || file.ArgumentIndex >= len(plan.Arguments) {
		return nil, errors.New("the launch plan names no argument for its file")
	}
	data, err := encodeArgumentFile(file.Text)
	if err != nil {
		return nil, err
	}
	path, err := writeArgumentFile(directory, data)
	if err != nil {
		return nil, err
	}
	arguments := append([]string(nil), plan.Arguments...)
	arguments[file.ArgumentIndex] = "@" + path
	return arguments, nil
}

// writeArgumentFile writes the argument file into directory, readable by the owner only.
// The file is made new, so a launch never reads another's.
func writeArgumentFile(directory string, data []byte) (string, error) {
	if directory == "" {
		return "", errors.New("the argument file has no directory")
	}
	path := filepath.Join(directory, argumentFileName)
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return "", err
	}
	if _, err := file.Write(data); err != nil {
		file.Close()
		os.Remove(path)
		return "", err
	}
	if err := file.Close(); err != nil {
		os.Remove(path)
		return "", err
	}
	return path, nil
}
