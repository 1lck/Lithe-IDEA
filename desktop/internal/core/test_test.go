package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// testsFixtureManifest is a build-system declaration with workspace tests and
// JUnit XML reports. Core validates it on every call, so this test exercises
// the real planning and decoding paths rather than a host-side copy.
const testsFixtureManifest = `{
  "schemaVersion": 0,
  "id": "dev.lithe.test.tests-fixture",
  "displayName": "Tests Fixture",
  "version": "0.1.0",
  "pluginAPIVersion": 0,
  "requires": {"buildSystems": 0},
  "vendor": {"id": "org.example", "displayName": "Example", "signatureRequirement": "publisherPackage"},
  "permissions": ["process.build"],
  "activationEvents": ["onBuildSystem:fixture-tests"],
  "languages": [],
  "buildSystems": [{
    "id": "fixture-tests",
    "displayName": "Fixture Tests",
    "detection": {"markers": ["fixture.test"]},
    "invocation": {"executables": [{"kind": "projectFile", "path": "run-tests"}]},
    "test": {
      "scopes": ["workspace"],
      "arguments": ["test"],
      "results": {"decoder": "junitXml", "reports": ["reports/*.xml"]}
    }
  }]
}`

func writeTestsReport(t *testing.T, root string) {
	t.Helper()
	reports := filepath.Join(root, "reports")
	if err := os.MkdirAll(reports, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "tests"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "tests", "fixture_test.go"), []byte("package fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	report := `<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="FixtureSuite">
  <testcase classname="FixtureSuite" name="passes" time="0.010"/>
  <testcase classname="FixtureSuite" name="fails" time="0.020" file="tests/fixture_test.go" line="12">
    <failure message="expected 2, got 3">trace</failure>
  </testcase>
</testsuite>`
	if err := os.WriteFile(filepath.Join(reports, "fixture.xml"), []byte(report), 0o600); err != nil {
		t.Fatal(err)
	}
}

func testsManifest(t *testing.T) json.RawMessage {
	t.Helper()
	if !json.Valid([]byte(testsFixtureManifest)) {
		t.Fatal("fixture manifest is not JSON")
	}
	return json.RawMessage(testsFixtureManifest)
}

func TestBuildTestPlanDecodesReportsAndResolvesOutcome(t *testing.T) {
	root := t.TempDir()
	writeTestsReport(t, root)
	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	plan, err := client.PlanBuildTest(ctx, testsManifest(t), "fixture-tests", BuildTestRequest{
		Root: ".", WorkspaceRoot: root,
	})
	if err != nil {
		t.Fatalf("PlanBuildTest: %v", err)
	}
	if len(plan.Arguments) != 1 || plan.Arguments[0] != "test" {
		t.Fatalf("plan arguments = %v, want the declared test command", plan.Arguments)
	}

	notBefore := int64(0)
	results, err := client.DecodeBuildTestResults(ctx, testsManifest(t), "fixture-tests", BuildTestResultsRequest{
		WorkspaceRoot: root, Root: ".", Output: "output", NotBeforeMillis: &notBefore,
	})
	if err != nil {
		t.Fatalf("DecodeBuildTestResults: %v", err)
	}
	if results.Summary.Total != 2 || results.Summary.Passed != 1 || results.Summary.Failed != 1 {
		t.Fatalf("summary = %+v, want 2 total, 1 passed, 1 failed", results.Summary)
	}
	if results.Success {
		t.Fatal("a failed case still reported success")
	}
	var failed *BuildTestCase
	for index := range results.Tests {
		if results.Tests[index].Case == "fails" {
			failed = &results.Tests[index]
		}
	}
	if failed == nil {
		t.Fatalf("decoded cases = %+v, want the failing case", results.Tests)
	}
	if failed.Path != "tests/fixture_test.go" || failed.Line == nil || *failed.Line != 12 {
		t.Fatalf("failure location = %q:%v, want tests/fixture_test.go:12", failed.Path, failed.Line)
	}
	if failed.Message != "expected 2, got 3" {
		t.Fatalf("failure message = %q", failed.Message)
	}

	exit := 1
	verdict, err := client.ResolveBuildTestOutcome(ctx, BuildTestTermination{Kind: "exited", ExitCode: &exit}, "", "", "", &results.Summary)
	if err != nil {
		t.Fatalf("ResolveBuildTestOutcome: %v", err)
	}
	if verdict.Outcome != "testsFailed" || verdict.Success {
		t.Fatalf("verdict = %+v, want testsFailed", verdict)
	}

	cancelled, err := client.ResolveBuildTestOutcome(ctx, BuildTestTermination{Kind: "cancelled"}, "", "", "", &results.Summary)
	if err != nil {
		t.Fatalf("ResolveBuildTestOutcome(cancelled): %v", err)
	}
	if cancelled.Outcome != "cancelled" || cancelled.Success {
		t.Fatalf("cancelled verdict = %+v, want cancelled", cancelled)
	}
}

func TestBuildTestOutcomeWithoutReportedTestsIsNotAPass(t *testing.T) {
	client := NewClient()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	zero := 0
	empty := BuildTestSummary{}
	verdict, err := client.ResolveBuildTestOutcome(ctx, BuildTestTermination{Kind: "exited", ExitCode: &zero}, "", "", "", &empty)
	if err != nil {
		t.Fatalf("ResolveBuildTestOutcome: %v", err)
	}
	if verdict.Outcome != "noTestsFound" {
		t.Fatalf("verdict = %+v, want noTestsFound for a workspace run that executed nothing", verdict)
	}
}
