package pluginhost

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/atomicfile"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginpkg"
)

// commandRecordName is the record of a plugin's installations, beside its
// versioned state directories. A version never has this name: it is not a
// version number.
const commandRecordName = "commands.json"

// commandInstallsName holds the managed install directories, one per installer.
const commandInstallsName = "commands"

// maxCommandRecordBytes bounds the record read on every launch that misses PATH.
// Sixteen installers with paths of a few hundred bytes fit with room to spare.
const maxCommandRecordBytes = 64 << 10

// installerIDPattern is the contract's installer ID: lowercase letters, digits
// and '-', at most 64 characters. Core checks it before the manifest installs;
// the host checks again because it joins the ID into a path.
var installerIDPattern = regexp.MustCompile(`^[a-z0-9-]{1,64}$`)

// ErrCommandRecord reports an installation the host refuses to record.
var ErrCommandRecord = errors.New("command installation not recordable")

// CommandInstallation is one recorded installation: the installer that ran, the
// target the user chose, and the absolute directory its commands landed in.
type CommandInstallation struct {
	Installer string `json:"installer"`
	Target    string `json:"target"`
	Directory string `json:"directory"`
}

type commandRecord struct {
	Installations []CommandInstallation `json:"installations"`
}

// CommandStore keeps the commands the host installed for plugins through their
// command installers, and the record of where each installation's commands
// landed.
//
// Everything lives below the plugin root's state directory,
// <root>/.state/<plugin ID>/, which the host owns and removes with the plugin
// (pluginpkg.RemoveState):
//
//   - commands/<installer ID>/ is the install directory of a managed
//     installation; the tool writes into it, the host creates it. A download
//     installer keeps its verified archive and the extraction below it in
//     <cache key>/, pluginruntime.Manager's layout; after an installation
//     records a new key, the host removes the others.
//   - commands.json records each installation's target and command directory,
//     so a toolDefault installation that landed in the tool's own directory
//     (such as GOPATH/bin) is found by later launches as well.
//
// The plugin root is in Application Support or %LOCALAPPDATA%, never in the app
// bundle or the installation directory, so none of this changes the code
// signature or the Sparkle delta base. Installations outlive plugin updates: an
// update replaces the package, not its state.
type CommandStore struct {
	// State is the plugin root's state directory, <root>/.state.
	State string

	mu sync.Mutex
}

func (s *CommandStore) pluginDirectory(pluginID string) (string, error) {
	if s == nil || s.State == "" || !filepath.IsAbs(s.State) {
		return "", fmt.Errorf("%w: no absolute state directory", ErrCommandRecord)
	}
	if err := pluginpkg.CheckIdentity("plugin ID", pluginID); err != nil {
		return "", err
	}
	return filepath.Join(s.State, pluginID), nil
}

// InstallDirectory is the directory a managed installation of installerID writes
// into. It is not created here; the installation creates it.
func (s *CommandStore) InstallDirectory(pluginID, installerID string) (string, error) {
	directory, err := s.pluginDirectory(pluginID)
	if err != nil {
		return "", err
	}
	if !installerIDPattern.MatchString(installerID) {
		return "", fmt.Errorf("%w: installer ID %q", ErrCommandRecord, installerID)
	}
	return filepath.Join(directory, commandInstallsName, installerID), nil
}

// Installations reads the plugin's recorded installations. A missing, oversized
// or unreadable record holds none: the commands are then looked for on PATH only
// and plugin management offers the installers again.
func (s *CommandStore) Installations(pluginID string) []CommandInstallation {
	directory, err := s.pluginDirectory(pluginID)
	if err != nil {
		return nil
	}
	return readCommandRecord(filepath.Join(directory, commandRecordName))
}

func readCommandRecord(path string) []CommandInstallation {
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, maxCommandRecordBytes+1))
	if err != nil || len(data) > maxCommandRecordBytes {
		return nil
	}
	var record commandRecord
	if json.Unmarshal(data, &record) != nil {
		return nil
	}
	installations := record.Installations[:0]
	for _, installation := range record.Installations {
		if installation.valid() {
			installations = append(installations, installation)
		}
	}
	return installations
}

func (i CommandInstallation) valid() bool {
	return installerIDPattern.MatchString(i.Installer) &&
		(i.Target == core.CommandInstallManaged || i.Target == core.CommandInstallToolDefault) &&
		filepath.IsAbs(i.Directory) && filepath.Clean(i.Directory) == i.Directory
}

// Directories lists the command directories of the plugin's installations:
// managed ones first, then the default directories, each once.
func (s *CommandStore) Directories(pluginID string) []string {
	installations := s.Installations(pluginID)
	directories := make([]string, 0, len(installations))
	seen := make(map[string]struct{}, len(installations))
	for _, target := range []string{core.CommandInstallManaged, core.CommandInstallToolDefault} {
		for _, installation := range installations {
			if installation.Target != target {
				continue
			}
			if _, ok := seen[installation.Directory]; ok {
				continue
			}
			seen[installation.Directory] = struct{}{}
			directories = append(directories, installation.Directory)
		}
	}
	return directories
}

// Record notes a finished installation, replacing an earlier one of the same
// installer. The record is written to a temporary file and renamed, so a crash
// leaves the old record or the new one.
func (s *CommandStore) Record(pluginID string, installation CommandInstallation) error {
	directory, err := s.pluginDirectory(pluginID)
	if err != nil {
		return err
	}
	installation.Directory = filepath.Clean(installation.Directory)
	if !installation.valid() {
		return fmt.Errorf("%w: %+v", ErrCommandRecord, installation)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	path := filepath.Join(directory, commandRecordName)
	installations := []CommandInstallation{installation}
	for _, existing := range readCommandRecord(path) {
		if existing.Installer != installation.Installer {
			installations = append(installations, existing)
		}
	}
	data, err := json.MarshalIndent(commandRecord{Installations: installations}, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	return atomicfile.Write(path, data, 0o600)
}

// Lookup is the command lookup of the plugin's systemCommand launches: base
// (PATH) first, then the directories the plugin's commands were installed into.
// The record is read only when base misses, and at most once per lookup.
func (s *CommandStore) Lookup(pluginID string, base func(name string) (string, error)) func(name string) (string, error) {
	var once sync.Once
	var directories []string
	return func(name string) (string, error) {
		if base != nil {
			if path, err := base(name); err == nil && path != "" {
				return path, nil
			}
		}
		once.Do(func() { directories = s.Directories(pluginID) })
		for _, directory := range directories {
			if path, err := CommandInDirectory(directory, name); err == nil {
				return path, nil
			}
		}
		return "", exec.ErrNotFound
	}
}

// CommandInDirectory finds the executable command in directory, with the
// platform's executable extensions on Windows. name must be a bare command name.
func CommandInDirectory(directory, name string) (string, error) {
	if name == "" || name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
		return "", exec.ErrNotFound
	}
	return exec.LookPath(filepath.Join(directory, name))
}

// The contract's codes of an installation that ran without providing its commands.
const (
	// CommandInstallFailedCode: the installation exited unsuccessfully.
	CommandInstallFailedCode = "plugin.commandInstaller.failed"
	// CommandInstallTimedOutCode: the installation ran past its timeout and was stopped.
	CommandInstallTimedOutCode = "plugin.commandInstaller.timedOut"
	// CommandInstallCommandsMissingCode: the installation finished but a command it provides
	// is not in its directory.
	CommandInstallCommandsMissingCode = "plugin.commandInstaller.commandsMissing"
	// CommandInstallDownloadFailedCode: no URL of a download installation delivered its
	// archive.
	CommandInstallDownloadFailedCode = "plugin.commandInstaller.downloadFailed"
	// CommandInstallChecksumMismatchCode: a download installation's archive does not have its
	// pinned SHA-256.
	CommandInstallChecksumMismatchCode = "plugin.commandInstaller.checksumMismatch"
	// CommandInstallArchiveInvalidCode: a download installation's archive is not a zip or
	// tar.gz whose entries extract safely below its strip prefix.
	CommandInstallArchiveInvalidCode = "plugin.commandInstaller.archiveInvalid"
)

// CommandInstallError is an installation that ran and did not provide its commands. Plugin
// management shows it in the user's language from the fields its code uses.
type CommandInstallError struct {
	// Code is one of the CommandInstall codes.
	Code string
	// ExitCode is the tool's exit code, for CommandInstallFailedCode; -1 when the tool ended
	// without one, such as on a signal.
	ExitCode int
	// Timeout is how long the installation was allowed, for CommandInstallTimedOutCode.
	Timeout time.Duration
	// Commands and Directory are the commands not found and where they were looked for, for
	// CommandInstallCommandsMissingCode.
	Commands  []string
	Directory string
	// Err is what went wrong, for the download codes; it is the host's own diagnostic and
	// not shown translated.
	Err error
}

func (e *CommandInstallError) Error() string {
	switch e.Code {
	case CommandInstallFailedCode:
		return fmt.Sprintf("%s: the installation exited with code %d", e.Code, e.ExitCode)
	case CommandInstallTimedOutCode:
		return fmt.Sprintf("%s: the installation ran past %s", e.Code, e.Timeout)
	case CommandInstallCommandsMissingCode:
		return fmt.Sprintf("%s: %s not in %s", e.Code, strings.Join(e.Commands, ", "), e.Directory)
	case CommandInstallDownloadFailedCode, CommandInstallChecksumMismatchCode, CommandInstallArchiveInvalidCode:
		if e.Err != nil {
			return fmt.Sprintf("%s: %v", e.Code, e.Err)
		}
	}
	return e.Code
}

func (e *CommandInstallError) Unwrap() error { return e.Err }
