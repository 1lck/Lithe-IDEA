// Package projectgen executes the generation plan Core produced for a project
// generator: it writes planned files, runs scaffolding commands, downloads and
// extracts archives inside a staging directory, then moves the finished project
// into place. Core owns every rule (fields, conditions, templates, the step
// list); this package only performs the I/O and process work, and never looks
// at a generator ID.
package projectgen

import (
	"context"
	"errors"
	"fmt"
	"github.com/1lck/Lithe-IDEA/desktop/internal/processledger"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

// Kernel is the part of the Core client the executor uses. *core.Client satisfies it.
type Kernel interface {
	ExtractProjectArchive(ctx context.Context, archivePath, destination string) (int, error)
	InitializeGit(ctx context.Context, root string) error
}

// Reason says why a run stopped. The window maps it to a localized message.
type Reason string

const (
	ReasonExists          Reason = "exists"
	ReasonInvalidLocation Reason = "invalidLocation"
	ReasonCancelled       Reason = "cancelled"
	ReasonCommandMissing  Reason = "commandMissing"
	ReasonCommandFailed   Reason = "commandFailed"
	ReasonTimedOut        Reason = "timedOut"
	ReasonDownloadFailed  Reason = "downloadFailed"
	ReasonArchiveInvalid  Reason = "archiveInvalid"
	ReasonStepFailed      Reason = "stepFailed"
	ReasonPinFailed       Reason = "pinFailed"
	ReasonGitFailed       Reason = "gitFailed"
)

// Failure is why a run did not finish. Err keeps the cause for the log; Tail is
// the last output of a failed command, for the window to show.
type Failure struct {
	Reason Reason
	Err    error
	Tail   string
}

func (f *Failure) Error() string { return fmt.Sprintf("projectgen: %s: %v", f.Reason, f.Err) }

// Unwrap exposes the cause so errors.Is(err, context.Canceled) works.
func (f *Failure) Unwrap() error { return f.Err }

// Command is the executable a bare command name resolved to and the environment
// it needs on top of the plan's own.
type Command struct {
	Executable  string
	Environment map[string]string
	PathPrepend []string
}

// Resolver finds the executable of a command step. A missing tool must return
// an error wrapping ErrCommandMissing.
type Resolver func(ctx context.Context, command string) (Command, error)

// ErrCommandMissing reports a command the resolver could not find.
var ErrCommandMissing = errors.New("projectgen: the command is not installed")

// LookPathResolver resolves a bare name on PATH, the fallback when the host has
// no tool definition for it.
func LookPathResolver(_ context.Context, command string) (Command, error) {
	path, err := lookPath(command)
	if err != nil {
		return Command{}, fmt.Errorf("%w: %s", ErrCommandMissing, command)
	}
	return Command{Executable: path}, nil
}

// EventKind separates the phases a run reports.
type EventKind int

const (
	// EventStep starts step Step of Steps; Text names its kind.
	EventStep EventKind = iota
	// EventOutput is one line of a command's output.
	EventOutput
)

// Event is one progress report. Observe runs on the run's goroutine and must
// return promptly.
type Event struct {
	Kind        EventKind
	Step, Steps int
	Text        string
}

// Request is one run. Parent must be absolute; Name was already checked by Core.
type Request struct {
	Parent, Name string
	Plan         core.ProjectGenerationPlan
	Git          bool
	Kernel       Kernel
	Resolve      Resolver
	// SavePins records the tool selections of the finished project. A failure
	// leaves the project in place and is reported as ReasonPinFailed.
	SavePins func(ctx context.Context, root string, plan core.ProjectGenerationPlan) error
	Observe  func(Event)
	// Client downloads archives; nil uses a default client.
	Client *http.Client
}

// Result is the outcome of a run. Path is set once the project directory
// exists; it is kept even when a later part (pins, Git) failed.
type Result struct {
	Path      string
	OpenFiles []string
	Failure   *Failure
}

const (
	defaultCommandTimeout = 600 * time.Second
	archiveTimeout        = 10 * time.Minute
	// outputTail bounds the output kept to explain a failed command.
	outputTail = 4096
)

func (r Request) observe(event Event) {
	if r.Observe != nil {
		r.Observe(event)
	}
}

// Run executes the plan in a staging directory beside the destination and moves
// it into place only when every step succeeded. Failure or cancellation before
// the move removes the staging directory and leaves nothing behind; a failure
// after the move (pins, Git) keeps the project and reports it.
func Run(ctx context.Context, request Request) Result {
	destination := filepath.Join(request.Parent, request.Name)
	if !filepath.IsAbs(request.Parent) || request.Name == "" || filepath.Base(destination) != request.Name {
		return fail(ReasonInvalidLocation, errors.New("invalid project location"), "")
	}
	if _, err := os.Lstat(destination); err == nil {
		return fail(ReasonExists, os.ErrExist, "")
	}
	if err := ctx.Err(); err != nil {
		return fail(ReasonCancelled, err, "")
	}
	if err := os.MkdirAll(request.Parent, 0o755); err != nil {
		return fail(ReasonStepFailed, err, "")
	}
	staging, err := os.MkdirTemp(request.Parent, "."+request.Name+".lithe-creating-")
	if err != nil {
		return fail(ReasonStepFailed, err, "")
	}
	moved := false
	defer func() {
		if !moved {
			_ = os.RemoveAll(staging)
		}
	}()
	if failure := runSteps(ctx, request, staging); failure != nil {
		return Result{Failure: failure}
	}
	if err := ctx.Err(); err != nil {
		return fail(ReasonCancelled, err, "")
	}
	// A directory that appeared while the steps ran must not be replaced. The
	// rename also refuses a non-empty directory on every platform.
	if _, err := os.Lstat(destination); err == nil {
		return fail(ReasonExists, os.ErrExist, "")
	}
	if err := os.Rename(staging, destination); err != nil {
		reason := ReasonStepFailed
		if errors.Is(err, os.ErrExist) {
			reason = ReasonExists
		}
		return fail(reason, err, "")
	}
	moved = true
	result := Result{Path: destination, OpenFiles: existingFiles(destination, request.Plan.OpenFiles)}
	if request.SavePins != nil && (len(request.Plan.ToolPins) > 0) {
		if err := request.SavePins(ctx, destination, request.Plan); err != nil {
			result.Failure = &Failure{Reason: ReasonPinFailed, Err: err}
			return result
		}
	}
	if request.Git {
		if err := ctx.Err(); err != nil {
			result.Failure = &Failure{Reason: ReasonCancelled, Err: err}
			return result
		}
		if err := request.Kernel.InitializeGit(ctx, destination); err != nil {
			result.Failure = &Failure{Reason: ReasonGitFailed, Err: err}
		}
	}
	return result
}

func fail(reason Reason, err error, tail string) Result {
	return Result{Failure: &Failure{Reason: reason, Err: err, Tail: tail}}
}

// existingFiles keeps the files to open that exist as regular files below root.
func existingFiles(root string, files []string) []string {
	var found []string
	for _, file := range files {
		segments, err := splitRelative(file)
		if err != nil {
			continue
		}
		path := filepath.Join(root, filepath.Join(segments...))
		if info, err := os.Lstat(path); err == nil && info.Mode().IsRegular() {
			found = append(found, file)
		}
	}
	return found
}

func runSteps(ctx context.Context, request Request, staging string) *Failure {
	steps := request.Plan.Steps
	for index, step := range steps {
		if err := ctx.Err(); err != nil {
			return &Failure{Reason: ReasonCancelled, Err: err}
		}
		request.observe(Event{Kind: EventStep, Step: index + 1, Steps: len(steps), Text: step.Kind})
		var failure *Failure
		switch step.Kind {
		case "writeFiles":
			failure = writeFiles(ctx, step, staging)
		case "command":
			failure = runCommand(ctx, request, step, staging)
		case "archive":
			failure = fetchArchive(ctx, request, step, staging)
		default:
			failure = &Failure{Reason: ReasonStepFailed, Err: fmt.Errorf("projectgen: unknown step kind %q", step.Kind)}
		}
		if failure != nil {
			// A cancellation that raced the step is still a cancellation.
			if err := ctx.Err(); err != nil && errors.Is(err, context.Canceled) && failure.Reason != ReasonCancelled {
				failure.Reason = ReasonCancelled
			}
			return failure
		}
	}
	return nil
}

func writeFiles(ctx context.Context, step core.ProjectPlanStep, staging string) *Failure {
	for _, file := range step.Files {
		if err := ctx.Err(); err != nil {
			return &Failure{Reason: ReasonCancelled, Err: err}
		}
		if err := writeFile(staging, file.Path, file.Contents, file.Executable); err != nil {
			return &Failure{Reason: ReasonStepFailed, Err: err}
		}
	}
	return nil
}

func fetchArchive(ctx context.Context, request Request, step core.ProjectPlanStep, staging string) *Failure {
	scratch, err := os.MkdirTemp("", "lithe-archive-*")
	if err != nil {
		return &Failure{Reason: ReasonStepFailed, Err: err}
	}
	defer os.RemoveAll(scratch)
	archive := filepath.Join(scratch, "project.zip")
	downloadCtx, cancel := context.WithTimeout(ctx, archiveTimeout)
	err = download(downloadCtx, request.Client, step.URL, archive)
	cancel()
	if err != nil {
		reason := ReasonDownloadFailed
		if errors.Is(err, context.DeadlineExceeded) && ctx.Err() == nil {
			reason = ReasonTimedOut
		}
		return &Failure{Reason: reason, Err: err}
	}
	if _, err := request.Kernel.ExtractProjectArchive(ctx, archive, staging); err != nil {
		reason := ReasonArchiveInvalid
		var rejection *core.ProjectRejection
		if !errors.As(err, &rejection) {
			reason = ReasonStepFailed
		}
		return &Failure{Reason: reason, Err: err}
	}
	return nil
}

func runCommand(ctx context.Context, request Request, step core.ProjectPlanStep, staging string) *Failure {
	resolve := request.Resolve
	if resolve == nil {
		resolve = LookPathResolver
	}
	command, err := resolve(ctx, step.Command)
	if err != nil {
		reason := ReasonStepFailed
		if errors.Is(err, ErrCommandMissing) {
			reason = ReasonCommandMissing
		}
		return &Failure{Reason: reason, Err: err}
	}
	environment := make(map[string]string, len(step.Environment)+len(command.Environment)+1)
	for name, value := range command.Environment {
		environment[name] = value
	}
	for name, value := range step.Environment {
		environment[name] = value
	}
	if len(command.PathPrepend) > 0 {
		current, set := environment["PATH"]
		if !set {
			current = os.Getenv("PATH")
		}
		parts := append(append([]string{}, command.PathPrepend...), current)
		environment["PATH"] = strings.Join(parts, string(filepath.ListSeparator))
	}
	timeout := time.Duration(step.TimeoutSeconds) * time.Second
	if timeout <= 0 {
		timeout = defaultCommandTimeout
	}
	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	lines := newLineSplitter(func(line string) { request.observe(Event{Kind: EventOutput, Text: line}) })
	process, err := buildprocess.Start(runCtx, buildprocess.Spec{
		Kind:             processledger.KindProcess,
		Executable:       command.Executable,
		Arguments:        step.Arguments,
		WorkingDirectory: staging,
		Environment:      environment,
	}, func(_ buildprocess.Stream, chunk string) { lines.write(chunk) })
	if err != nil {
		return &Failure{Reason: ReasonStepFailed, Err: err}
	}
	waitErr := process.Wait()
	lines.flush()
	if err := ctx.Err(); err != nil {
		return &Failure{Reason: ReasonCancelled, Err: err, Tail: lines.tail()}
	}
	if runCtx.Err() != nil {
		return &Failure{Reason: ReasonTimedOut, Err: runCtx.Err(), Tail: lines.tail()}
	}
	if waitErr != nil {
		return &Failure{Reason: ReasonCommandFailed, Err: waitErr, Tail: lines.tail()}
	}
	if step.Collect != nil && *step.Collect != "" {
		if err := collectDirectory(staging, *step.Collect); err != nil {
			return &Failure{Reason: ReasonStepFailed, Err: err}
		}
	}
	return nil
}
