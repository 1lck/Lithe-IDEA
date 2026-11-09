package core

import (
	"context"
	"encoding/json"
)

// BuildTestRequest is the selection a build-system test plan runs. Core decides
// whether the declaration can express the selection; the host only names what
// the user asked for. Paths are workspace-relative with forward slashes.
type BuildTestRequest struct {
	Root          string                     `json:"root"`
	Options       map[string]json.RawMessage `json:"options,omitempty"`
	WorkspaceRoot string                     `json:"workspaceRoot,omitempty"`
	Project       *BuildSelection            `json:"project,omitempty"`
	Target        *BuildSelection            `json:"target,omitempty"`
	Suite         string                     `json:"suite,omitempty"`
	Case          string                     `json:"case,omitempty"`
	UserArguments []string                   `json:"userArguments,omitempty"`
	Projects      []string                   `json:"projects,omitempty"`
}

// BuildTestResultsRequest asks Core to normalize the results of one test run.
// Result carries the canonical document a provider returned through
// lithe/build/test; command plans leave it nil and Core reads the declared
// report files itself. Output is the run's combined console text.
type BuildTestResultsRequest struct {
	WorkspaceRoot   string          `json:"workspaceRoot"`
	Root            string          `json:"root"`
	Project         string          `json:"project,omitempty"`
	Projects        []string        `json:"projects,omitempty"`
	Output          string          `json:"output,omitempty"`
	Result          json.RawMessage `json:"result,omitempty"`
	NotBeforeMillis *int64          `json:"notBeforeMillis,omitempty"`
}

// BuildTestCase is one normalized test outcome Core decoded. Path and Line are
// the failure location a report declared; they are empty for reports that only
// name the case.
type BuildTestCase struct {
	Project        string `json:"project,omitempty"`
	Suite          string `json:"suite"`
	Case           string `json:"case"`
	Status         string `json:"status"`
	Message        string `json:"message,omitempty"`
	DurationMillis *int64 `json:"durationMillis,omitempty"`
	Path           string `json:"path,omitempty"`
	Line           *int   `json:"line,omitempty"`
	Invocations    int    `json:"invocations"`
}

// BuildTestSummary counts the decoded cases by status.
type BuildTestSummary struct {
	Total   int `json:"total"`
	Passed  int `json:"passed"`
	Failed  int `json:"failed"`
	Errors  int `json:"errors"`
	Skipped int `json:"skipped"`
}

// BuildTestResults is Core's normalized answer to build.decodeTestResults.
type BuildTestResults struct {
	Tests    []BuildTestCase   `json:"tests"`
	Summary  BuildTestSummary  `json:"summary"`
	Success  bool              `json:"success"`
	Coverage []json.RawMessage `json:"coverage,omitempty"`
}

// BuildTestTermination says how a test process ended, as the host observed it.
// Kind is "exited", "timedOut" or "cancelled".
type BuildTestTermination struct {
	Kind     string `json:"kind"`
	ExitCode *int   `json:"exitCode,omitempty"`
}

// BuildTestVerdict is Core's unified result of build.resolveTestRunOutcome.
// Outcome is "passed", "testsFailed", "exitedWithError", "noTestsMatched",
// "noTestsFound", "timedOut" or "cancelled".
type BuildTestVerdict struct {
	Outcome  string `json:"outcome"`
	Success  bool   `json:"success"`
	ExitCode *int   `json:"exitCode,omitempty"`
}

// PlanBuildTest expands one declared test selection into the command or provider
// request that runs it. Core owns the selection rules; a rejected selection is
// returned as *MarketplaceRejection.
func (c *Client) PlanBuildTest(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildTestRequest) (BuildPlan, error) {
	const command = "build.testPlan"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage  `json:"manifest"`
		BuildSystemID string           `json:"buildSystemID"`
		WorkspaceRoot string           `json:"workspaceRoot,omitempty"`
		Request       BuildTestRequest `json:"request"`
	}{manifest, buildSystemID, request.WorkspaceRoot, request}, &result); err != nil {
		return BuildPlan{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildPlan{}, err
	}
	if result.Plan == nil {
		return BuildPlan{}, newParseError(command, "build test plan returned no plan", "")
	}
	return *result.Plan, nil
}

// DecodeBuildTestResults normalizes one run's reports. Core validates the
// reports and aggregates repeated invocations; the host never parses a report
// format itself.
func (c *Client) DecodeBuildTestResults(ctx context.Context, manifest json.RawMessage, buildSystemID string, request BuildTestResultsRequest) (BuildTestResults, error) {
	const command = "build.decodeTestResults"
	var result buildOutcome
	if err := c.Execute(ctx, command, struct {
		Manifest      json.RawMessage         `json:"manifest"`
		BuildSystemID string                  `json:"buildSystemID"`
		Request       BuildTestResultsRequest `json:"request"`
	}{manifest, buildSystemID, request}, &result); err != nil {
		return BuildTestResults{}, err
	}
	if err := result.failure(command); err != nil {
		return BuildTestResults{}, err
	}
	if result.Results == nil {
		return BuildTestResults{}, newParseError(command, "build test results returned no results", "")
	}
	return *result.Results, nil
}

// ResolveBuildTestOutcome reduces the observed termination and the decoded
// summary to Core's one tool-neutral verdict. An interrupted run never claims
// a test outcome.
func (c *Client) ResolveBuildTestOutcome(ctx context.Context, termination BuildTestTermination, project, suite, caseName string, summary *BuildTestSummary) (BuildTestVerdict, error) {
	const command = "build.resolveTestRunOutcome"
	scope := "workspace"
	switch {
	case caseName != "":
		scope = "case"
	case suite != "":
		scope = "suite"
	case project != "":
		scope = "project"
	}
	var verdict BuildTestVerdict
	payload := struct {
		Termination BuildTestTermination `json:"termination"`
		Scope       string               `json:"scope"`
		Summary     *BuildTestSummary    `json:"summary,omitempty"`
	}{termination, scope, summary}
	if err := c.Execute(ctx, command, payload, &verdict); err != nil {
		return BuildTestVerdict{}, err
	}
	if verdict.Outcome == "" {
		return BuildTestVerdict{}, newParseError(command, "test outcome returned no verdict", "")
	}
	return verdict, nil
}
