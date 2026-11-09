package workbench

import (
	"context"
	"encoding/json"
	"errors"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/buildprocess"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
)

const (
	// testRequestTimeout bounds one test run, like a build task. The provider or
	// process may take as long as a full build; the limit still makes the run
	// finite when a tool hangs.
	testRequestTimeout = 30 * time.Minute
	// testStopTimeout bounds asking a provider to cancel its request.
	testStopTimeout = 15 * time.Second
	// The result console and the failure detail are bounded like build output so
	// a chatty test tool cannot grow the window without limit.
	testOutputMaxLines = 2000
	testOutputLineSize = 16 << 10
	testOutputBytes    = 2 << 20
	// testMaxRows bounds the flattened result tree. Core already caps decoded
	// cases at 10 000; the tree keeps the same ceiling so a future Core change
	// cannot make the window unbounded.
	testMaxRows = 10_000
)

// testState is the Tests tool window's state for one project. Fields are read
// and written on the window thread; the operation may be used from the
// background goroutine but its own methods are synchronized.
type testState struct {
	running  bool
	stopping bool
	// failed is a run or decode failure shown in place of the summary.
	failed string
	// status is the last progress line under the toolbar.
	status string
	// output is the bounded console, oldest lines first.
	output      []string
	outputBytes int

	results    core.BuildTestResults
	verdict    core.BuildTestVerdict
	hasResults bool
	// rows is the flattened result tree: a suite header or one case.
	rows      []testRow
	operation *testOperation
	// generation rejects a result a newer run or selection replaced.
	generation uint64
}

func (s *testState) reset() { *s = testState{} }

// testOperation is the one provider request or host process a test run owns.
// stopped is set on the window thread and read by the run goroutine.
type testOperation struct {
	buildOperation
	stopped atomic.Bool
}

// testRow is one flat row of the result tree. suite rows have no case index.
type testRow struct {
	header bool
	// project and suite name a header; index is a case in results.Tests.
	project string
	suite   string
	index   int
}

// testInstance returns the first build instance whose declaration offers
// workspace-scope tests. Core decides whether the declaration is valid; this
// is only which instance the window can offer without a model selection.
func (p *project) testInstance() *buildInstance {
	if p == nil {
		return nil
	}
	for index := range p.build.instances {
		instance := &p.build.instances[index]
		if instance.System.Test == nil {
			continue
		}
		for _, scope := range instance.System.Test.Scopes {
			if scope == "workspace" {
				return instance
			}
		}
	}
	return nil
}

// runTests plans and runs the workspace-scope test selection of the first
// test-capable build system. Core owns the selection rules and the result
// decoding; this function owns only the process, cancellation and publication.
func (a *App) runTests(p *project) {
	if p == nil || p.tests.running {
		return
	}
	instance := p.testInstance()
	if instance == nil {
		a.notify(a.text.Tests.NoSystems)
		return
	}
	p.tests.generation++
	generation := p.tests.generation
	p.tests.running = true
	p.tests.stopping = false
	p.tests.failed = ""
	p.tests.hasResults = false
	p.tests.results = core.BuildTestResults{}
	p.tests.verdict = core.BuildTestVerdict{}
	p.tests.rows = nil
	p.tests.output = nil
	p.tests.outputBytes = 0
	p.tests.status = a.text.Tests.Preparing
	captured := *instance
	startedMillis := time.Now().UnixMilli()
	a.emit(core.LevelInfo, "app.action.performed", map[string]any{"action": "tests.run", "surface": "tests"})
	a.background(p, testRequestTimeout, func(ctx context.Context) func(*App) {
		return a.executeTestRun(ctx, p, captured, generation, startedMillis)
	})
}

// executeTestRun runs on a background goroutine. It posts progress and returns
// the publication callback; Core calls happen here, never on the window thread.
func (a *App) executeTestRun(ctx context.Context, p *project, instance buildInstance, generation uint64, startedMillis int64) func(*App) {
	request := core.BuildTestRequest{
		Root:          instance.Root,
		Options:       instance.Options,
		WorkspaceRoot: p.root,
	}
	plan, err := a.kernel.PlanBuildTest(ctx, instance.Manifest, instance.BuildSystemID, request)
	if err != nil {
		return func(a *App) { a.finishTestError(p, generation, err) }
	}
	if plan.Provider == nil {
		return a.executeTestCommand(ctx, p, instance, plan, generation, startedMillis)
	}
	return a.executeTestProvider(ctx, p, instance, plan, generation, startedMillis)
}

// executeTestCommand resolves the executable through Core's candidate order,
// runs it, and normalizes its declared reports.
func (a *App) executeTestCommand(ctx context.Context, p *project, instance buildInstance, plan core.BuildPlan, generation uint64, startedMillis int64) func(*App) {
	executable, err := a.resolveBuildExecutable(ctx, p, instance, a.text.Build)
	if err != nil {
		return func(a *App) { a.finishTestError(p, generation, err) }
	}
	output := &testOutput{}
	operation := &testOperation{}
	workingDirectory := filepath.Join(p.root, filepath.FromSlash(plan.WorkingDirectory))
	process, err := buildprocess.Start(ctx, buildprocess.Spec{
		Executable:       executable,
		Arguments:        plan.Arguments,
		WorkingDirectory: workingDirectory,
		Environment:      plan.Environment,
	}, func(_ buildprocess.Stream, text string) {
		output.append(text)
		a.post(func(a *App) { a.appendTestOutput(p, generation, text) })
	})
	if err != nil {
		return func(a *App) { a.finishTestError(p, generation, err) }
	}
	operation.process = process
	a.post(func(a *App) {
		if a.project != p || p.tests.generation != generation {
			return
		}
		p.tests.operation = operation
		p.tests.status = a.text.Tests.Running
	})
	waitErr := process.Wait()
	termination, interrupted := testTermination(ctx, operation, waitErr)
	if interrupted {
		return func(a *App) { a.finishTestInterrupted(p, generation, termination) }
	}
	result, decodeErr := a.decodeTestResults(ctx, p, instance, testResultsRequest(p, instance, output.text(), nil, startedMillis))
	if decodeErr != nil {
		return func(a *App) { a.finishTestError(p, generation, decodeErr) }
	}
	return func(a *App) { a.finishTestRun(p, generation, result, termination) }
}

// executeTestProvider runs the provider's lithe/build/test request. The reply's
// canonical report, when negotiated, is passed back to Core without parsing.
func (a *App) executeTestProvider(ctx context.Context, p *project, instance buildInstance, plan core.BuildPlan, generation uint64, startedMillis int64) func(*App) {
	client, err := a.buildProvider(ctx, p, instance)
	if err != nil {
		return func(a *App) { a.finishTestError(p, generation, err) }
	}
	operation, err := client.Execute(ctx, plan.Provider.Method, plan.Provider.Params, int(testRequestTimeout/time.Millisecond))
	if err != nil {
		return func(a *App) { a.finishTestError(p, generation, err) }
	}
	testOp := &testOperation{}
	testOp.provider, testOp.request = client, operation
	a.post(func(a *App) {
		if a.project != p || p.tests.generation != generation {
			return
		}
		p.tests.operation = testOp
		p.tests.status = a.text.Tests.Running
	})
	output := &testOutput{}
	var providerResult json.RawMessage
	for {
		select {
		case progress, ok := <-operation.Progress():
			if !ok {
				goto completed
			}
			if progress.Output != "" {
				output.append(progress.Output)
				a.post(func(a *App) { a.appendTestOutput(p, generation, progress.Output) })
			}
			if progress.Message != "" {
				message := progress.Message
				a.post(func(a *App) {
					if a.project == p && p.tests.generation == generation {
						p.tests.status = message
					}
				})
			}
		case <-ctx.Done():
			return func(a *App) { a.finishTestInterrupted(p, generation, testContextTermination(ctx)) }
		}
	}
completed:
	raw, waitErr := operation.Wait(ctx)
	termination, interrupted := testTermination(ctx, testOp, waitErr)
	if interrupted {
		return func(a *App) { a.finishTestInterrupted(p, generation, termination) }
	}
	if waitErr != nil {
		return func(a *App) { a.finishTestError(p, generation, waitErr) }
	}
	var execution struct {
		ExitCode    *int            `json:"exitCode"`
		Output      string          `json:"output"`
		TestResults json.RawMessage `json:"testResults"`
	}
	if err := json.Unmarshal(raw, &execution); err != nil {
		return func(a *App) { a.finishTestError(p, generation, err) }
	}
	if execution.ExitCode != nil {
		termination = core.BuildTestTermination{Kind: "exited", ExitCode: execution.ExitCode}
	}
	if execution.Output != "" && output.len() == 0 {
		output.append(execution.Output)
		a.post(func(a *App) { a.appendTestOutput(p, generation, execution.Output) })
	}
	providerResult = execution.TestResults
	request := testResultsRequest(p, instance, output.text(), providerResult, startedMillis)
	result, decodeErr := a.decodeTestResults(ctx, p, instance, request)
	if decodeErr != nil {
		return func(a *App) { a.finishTestError(p, generation, decodeErr) }
	}
	return func(a *App) { a.finishTestRun(p, generation, result, termination) }
}

// testResultsRequest builds the decode request. notBeforeMillis is the host's
// wall clock because Core compares it with report file times, which are not the
// window's injected clock.
func testResultsRequest(p *project, instance buildInstance, output string, result json.RawMessage, startedMillis int64) core.BuildTestResultsRequest {
	request := core.BuildTestResultsRequest{
		WorkspaceRoot:   p.root,
		Root:            instance.Root,
		Output:          output,
		NotBeforeMillis: &startedMillis,
	}
	if len(result) != 0 && string(result) != "null" {
		request.Result = result
	}
	return request
}

func (a *App) decodeTestResults(ctx context.Context, p *project, instance buildInstance, request core.BuildTestResultsRequest) (core.BuildTestResults, error) {
	return a.kernel.DecodeBuildTestResults(ctx, instance.Manifest, instance.BuildSystemID, request)
}

// testTermination classifies how the test process or provider ended. A run the
// user stopped or the host's deadline ended never claims a test outcome.
func testTermination(ctx context.Context, operation *testOperation, waitErr error) (core.BuildTestTermination, bool) {
	if operation != nil && operation.stopped.Load() {
		return core.BuildTestTermination{Kind: "cancelled"}, true
	}
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return core.BuildTestTermination{Kind: "timedOut"}, true
	}
	if ctx.Err() != nil {
		return testContextTermination(ctx), true
	}
	termination := core.BuildTestTermination{Kind: "exited"}
	var exitErr *exec.ExitError
	if errors.As(waitErr, &exitErr) {
		code := exitErr.ExitCode()
		termination.ExitCode = &code
	} else if waitErr != nil {
		code := 1
		termination.ExitCode = &code
	} else {
		code := 0
		termination.ExitCode = &code
	}
	return termination, false
}

func testContextTermination(ctx context.Context) core.BuildTestTermination {
	if errors.Is(ctx.Err(), context.DeadlineExceeded) {
		return core.BuildTestTermination{Kind: "timedOut"}
	}
	return core.BuildTestTermination{Kind: "cancelled"}
}

// finishTestRun reduces the run through Core and publishes the result tree.
func (a *App) finishTestRun(p *project, generation uint64, results core.BuildTestResults, termination core.BuildTestTermination) {
	if a.project != p || p.tests.generation != generation {
		return
	}
	verdict, err := a.kernel.ResolveBuildTestOutcome(context.Background(), termination, "", "", "", &results.Summary)
	if err != nil {
		a.finishTestError(p, generation, err)
		return
	}
	p.tests.operation = nil
	p.tests.running = false
	p.tests.stopping = false
	p.tests.results = results
	p.tests.verdict = verdict
	p.tests.hasResults = true
	p.tests.status = a.testVerdictStatus(verdict, results.Summary)
	p.tests.rows = flattenTestRows(results)
}

// finishTestInterrupted publishes a cancelled or timed-out run without
// pretending it produced a test outcome.
func (a *App) finishTestInterrupted(p *project, generation uint64, termination core.BuildTestTermination) {
	if a.project != p || p.tests.generation != generation {
		return
	}
	verdict, err := a.kernel.ResolveBuildTestOutcome(context.Background(), termination, "", "", "", nil)
	if err != nil {
		a.finishTestError(p, generation, err)
		return
	}
	p.tests.operation = nil
	p.tests.running = false
	p.tests.stopping = false
	p.tests.verdict = verdict
	p.tests.hasResults = false
	p.tests.rows = nil
	p.tests.results = core.BuildTestResults{}
	if verdict.Outcome == "cancelled" {
		p.tests.status = a.text.Tests.Cancelled
	} else {
		p.tests.status = a.text.Tests.TimedOut
	}
}

// finishTestError reports a planning, launch or decode failure without claiming
// a test result.
func (a *App) finishTestError(p *project, generation uint64, err error) {
	if a.project != p || p.tests.generation != generation {
		return
	}
	p.tests.operation = nil
	p.tests.running = false
	p.tests.stopping = false
	if errors.Is(err, context.Canceled) {
		p.tests.status = a.text.Tests.Cancelled
		return
	}
	p.tests.failed = a.text.Tests.ResultsUnavailable(err.Error())
	p.tests.status = a.text.Tests.ResultsUnavailable(err.Error())
	a.emit(operationFailedLevel, operationFailedEvent, operationFailedFields("tests", err))
}

// stopTests stops the process and asks the provider to cancel. The terminal
// event still clears the operation, so a replacement run cannot start until the
// current one really ended.
func (a *App) stopTests(p *project) {
	if p == nil || p.tests.operation == nil {
		return
	}
	operation := p.tests.operation
	operation.stopped.Store(true)
	operation.stop()
	p.tests.stopping = true
	p.tests.status = a.text.Tests.Stopping
	if operation.provider != nil && operation.request != nil {
		client, request := operation.provider, operation.request
		a.background(p, testStopTimeout, func(ctx context.Context) func(*App) {
			_ = client.Cancel(ctx, request)
			return nil
		})
	}
}

// stopTestsForProject ends a run and drops its state when the project closes.
func (a *App) stopTestsForProject(p *project) {
	if p == nil {
		return
	}
	if operation := p.tests.operation; operation != nil {
		operation.stopped.Store(true)
		operation.stop()
	}
	p.tests.reset()
}

// testVerdictStatus is the summary line under the toolbar.
func (a *App) testVerdictStatus(verdict core.BuildTestVerdict, summary core.BuildTestSummary) string {
	switch verdict.Outcome {
	case "passed":
		return a.text.Tests.Passed
	case "testsFailed":
		return a.text.Tests.Failed
	case "exitedWithError":
		return a.text.Tests.ExitedWithError
	case "noTestsMatched":
		return a.text.Tests.NoTestsMatched
	case "noTestsFound":
		return a.text.Tests.NoTestsFound
	case "timedOut":
		return a.text.Tests.TimedOut
	case "cancelled":
		return a.text.Tests.Cancelled
	}
	return a.text.Tests.Summary(summary.Passed, summary.Failed, summary.Skipped)
}

// flattenTestRows turns Core's ordered cases into grouped rows, bounded by the
// same ceiling Core applies.
func flattenTestRows(results core.BuildTestResults) []testRow {
	rows := make([]testRow, 0, len(results.Tests)+8)
	lastKey := ""
	for index, test := range results.Tests {
		if len(rows) >= testMaxRows {
			break
		}
		key := test.Project + "\x00" + test.Suite
		if key != lastKey {
			rows = append(rows, testRow{header: true, project: test.Project, suite: test.Suite})
			lastKey = key
		}
		if len(rows) >= testMaxRows {
			break
		}
		rows = append(rows, testRow{index: index})
	}
	return rows
}

// appendTestOutput adds one chunk to the bounded console, keeping whole lines
// where possible as the Build window does.
func (a *App) appendTestOutput(p *project, generation uint64, text string) {
	if p == nil || a.project != p || p.tests.generation != generation || text == "" {
		return
	}
	for len(text) > 0 {
		line := text
		if newline := strings.IndexByte(text, '\n'); newline >= 0 {
			line, text = text[:newline+1], text[newline+1:]
		} else {
			text = ""
		}
		if len(line) > testOutputLineSize {
			line = line[:testOutputLineSize]
		}
		p.tests.output = append(p.tests.output, line)
		p.tests.outputBytes += len(line)
	}
	for len(p.tests.output) > testOutputMaxLines || (p.tests.outputBytes > testOutputBytes && len(p.tests.output) > 1) {
		p.tests.outputBytes -= len(p.tests.output[0])
		p.tests.output = p.tests.output[1:]
	}
}

// formatTestDuration renders a decoded duration without inventing precision.
func formatTestDuration(millis int) string {
	return strconv.Itoa(millis) + " ms"
}

// testOutput collects the full run text for Core's decode request while the
// window receives the same text in bounded chunks.
type testOutput struct {
	mu      sync.Mutex
	builder strings.Builder
}

func (o *testOutput) append(text string) {
	o.mu.Lock()
	if o.builder.Len() < testOutputBytes*2 {
		o.builder.WriteString(text)
	}
	o.mu.Unlock()
}

func (o *testOutput) text() string {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.builder.String()
}

func (o *testOutput) len() int {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.builder.Len()
}
