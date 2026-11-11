package workbench

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/contractfixture"
	"github.com/1lck/Lithe-IDEA/desktop/internal/core"
	"github.com/1lck/Lithe-IDEA/desktop/internal/pluginservice"
)

// planBlockingKernel is the real Core whose build plan never arrives: PlanBuildTask reports that
// it was asked and waits until its context ends, so an execution stays in preparation until it
// is stopped.
type planBlockingKernel struct {
	*testKernel
	planning chan struct{}
}

func (k *planBlockingKernel) PlanBuildTask(ctx context.Context, _ json.RawMessage, _ string, _ core.BuildPlanRequest) (core.BuildPlan, error) {
	k.planning <- struct{}{}
	<-ctx.Done()
	return core.BuildPlan{}, ctx.Err()
}

// awaitPlanning waits until the kernel was asked for a plan. The request is made on a
// background goroutine, so nothing on the window thread has to run for it.
func (k *planBlockingKernel) awaitPlanning(t *testing.T) {
	t.Helper()
	select {
	case <-k.planning:
	case <-time.After(10 * time.Second):
		t.Fatal("the execution did not ask for its plan before the deadline")
	}
}

// ideAPICall dispatches one tool call off the window thread, as the broker does, and pumps
// the window until it is answered.
func ideAPICall(t *testing.T, h *harness, conn *ideAPIConnection, tool string, arguments any) any {
	t.Helper()
	raw, err := json.Marshal(arguments)
	if err != nil {
		t.Fatal(err)
	}
	var result any
	answered := false
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		answer := h.app.ideAPIDispatch(ctx, conn, tool, raw)
		h.app.post(func(*App) { result, answered = answer, true })
	}()
	awaitStateWithin(t, h, 25*time.Second, tool+" to answer", func() bool { return answered })
	return result
}

// ideAPIObject decodes a tool's value, which Core answers as JSON and the window as a map.
func ideAPIObject(t *testing.T, result any) map[string]any {
	t.Helper()
	switch value := result.(type) {
	case map[string]any:
		return value
	case json.RawMessage:
		var decoded map[string]any
		if err := json.Unmarshal(value, &decoded); err != nil {
			t.Fatalf("decode %s: %v", value, err)
		}
		return decoded
	}
	t.Fatalf("unexpected answer %#v", result)
	return nil
}

// ideAPIProject opens a temporary project in h and returns it with a connection to it.
func ideAPIProject(t *testing.T, h *harness) (*project, *ideAPIConnection) {
	t.Helper()
	h.open(t.TempDir())
	p := h.app.project
	awaitStateWithin(t, h, 10*time.Second, "the project's build detection", func() bool { return !p.build.loading })
	h.settle()
	return p, &ideAPIConnection{workspaceKey: p.root, permissions: core.IDEPermissions{Configure: true, Execute: true}}
}

// TestIDEBuildExecuteReservesTheWindowUntilItsExecutionEnds drives one execution through the
// tools while its plan is still being made: the start answers with the preparing execution and
// the window refuses a second one, the list and stop act on it before it launched, stopping it
// ends it as cancelled without an exit code, and the next execution expires its ID.
func TestIDEBuildExecuteReservesTheWindowUntilItsExecutionEnds(t *testing.T) {
	kernel := &planBlockingKernel{testKernel: &testKernel{Client: core.NewClient()}, planning: make(chan struct{}, 4)}
	h := newHarness(t, kernel)
	p, conn := ideAPIProject(t, h)
	p.build.instances = []buildInstance{{
		BuildInstance: core.BuildInstance{ID: "cargo", BuildSystemID: "cargo", DisplayName: "Cargo", Root: "."},
		System:        pluginservice.BuildSystemDeclaration{Tasks: []pluginservice.BuildTaskDeclaration{{ID: "build", DisplayName: "Build"}}},
		modelLoaded:   true,
	}}
	execute := map[string]any{"instanceID": "cargo", "taskID": "build"}

	started := ideAPIObject(t, ideAPICall(t, h, conn, "lithe_build_execute", execute))
	first, _ := started["operationID"].(string)
	if first == "" || started["state"] != "preparing" {
		t.Fatalf("the start answered %#v, want the preparing execution", started)
	}
	kernel.awaitPlanning(t)
	if code := ideAPIFailureCode(ideAPICall(t, h, conn, "lithe_build_execute", execute)); code != "BUSY" {
		t.Fatalf("a second start answered %q while the first was preparing, want BUSY", code)
	}
	if _, err := h.app.runBuildTask(p, "", "", "build", nil); err != errBuildBusy {
		t.Fatalf("the Build window's own start answered %v while a tool's execution was preparing", err)
	}
	configure := map[string]any{"instanceID": "cargo", "optionID": "release", "value": true}
	if code := ideAPIFailureCode(ideAPICall(t, h, conn, "lithe_build_configure", configure)); code != "BUSY" {
		t.Fatalf("an option edit answered %q during an execution, want BUSY", code)
	}
	listed := ideAPIObject(t, ideAPICall(t, h, conn, "lithe_operations_list", nil))["operations"].([]map[string]any)
	if len(listed) != 1 || listed[0]["operationID"] != first || listed[0]["state"] != "preparing" || listed[0]["exitCode"] != nil {
		t.Fatalf("operations %#v, want the preparing execution", listed)
	}

	stop := map[string]any{"operationID": first}
	if stopped := ideAPIObject(t, ideAPICall(t, h, conn, "lithe_operation_stop", stop)); stopped["state"] != "stopping" {
		t.Fatalf("the stop answered %#v, want stopping", stopped)
	}
	awaitStateWithin(t, h, 10*time.Second, "the stopped execution to end", func() bool { return p.ideAPI.current.State == "cancelled" })
	if p.build.operation != nil || p.ideAPI.current.ExitCode != nil {
		t.Fatalf("after the stop: window operation %v, execution %+v", p.build.operation, p.ideAPI.current)
	}
	output := ideAPIObject(t, ideAPICall(t, h, conn, "lithe_operation_output", map[string]any{"operationID": first}))
	if output["state"] != "cancelled" || output["exitCode"] != nil || output["output"] != "" || output["hasMore"] != false || output["reset"] != false {
		t.Fatalf("the cancelled execution's output %#v", output)
	}
	if again := ideAPIObject(t, ideAPICall(t, h, conn, "lithe_operation_stop", stop)); again["state"] != "cancelled" {
		t.Fatalf("stopping an ended execution answered %#v, want its state unchanged", again)
	}

	restarted := ideAPIObject(t, ideAPICall(t, h, conn, "lithe_build_execute", execute))
	second, _ := restarted["operationID"].(string)
	if second == "" || second == first || restarted["state"] != "preparing" {
		t.Fatalf("the next start answered %#v after %s", restarted, first)
	}
	kernel.awaitPlanning(t)
	for _, tool := range []string{"lithe_operation_output", "lithe_operation_stop"} {
		if code := ideAPIFailureCode(ideAPICall(t, h, conn, tool, stop)); code != "OPERATION_EXPIRED" {
			t.Fatalf("%s of the replaced execution answered %q, want OPERATION_EXPIRED", tool, code)
		}
	}
	if code := ideAPIFailureCode(ideAPICall(t, h, conn, "lithe_run_restart", map[string]any{"operationID": second})); code != "NOT_AVAILABLE" {
		t.Fatalf("restarting a build task answered %q, want NOT_AVAILABLE", code)
	}
	// The window's own Stop acts on the execution a tool started; between the stop and its
	// end the window says it is stopping.
	h.app.stopBuildOperation(p)
	if p.build.status != h.app.text.Build.Stopping || p.ideAPI.current.State != "stopping" {
		t.Fatalf("while stopping, the Build window says %q and the execution is %s", p.build.status, p.ideAPI.current.State)
	}
	awaitStateWithin(t, h, 10*time.Second, "the second execution to end", func() bool { return p.ideAPI.current.State == "cancelled" })
}

// TestIDEOperationOutputIsPagedByCore reads an execution's output through Core's pages: the
// pages join to the output, a page never exceeds Core's bound or splits a character, a read at
// the end has nothing new until more output arrives, and a cursor into output the bounded
// console dropped starts again with reset set.
func TestIDEOperationOutputIsPagedByCore(t *testing.T) {
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p, conn := ideAPIProject(t, h)
	op := h.app.beginBuildOperation(p, "build", "Cargo: build", "")
	var want strings.Builder
	for i := 0; i < 2000; i++ {
		line := fmt.Sprintf("%04d 编译 %s\n", i, strings.Repeat("é", 20))
		want.WriteString(line)
		h.app.appendBuildOutput(p, op, line)
	}
	read := func(cursor string) map[string]any {
		t.Helper()
		arguments := map[string]any{"operationID": op.ide.ID}
		if cursor != "" {
			arguments["cursor"] = cursor
		}
		return ideAPIObject(t, ideAPICall(t, h, conn, "lithe_operation_output", arguments))
	}

	var got strings.Builder
	cursor, firstCursor := "", ""
	for pages := 1; ; pages++ {
		page := read(cursor)
		text, _ := page["output"].(string)
		if page["reset"] != false || len(text) > 32<<10 || len(text) == 0 {
			t.Fatalf("page %d has %d bytes, reset %v", pages, len(text), page["reset"])
		}
		got.WriteString(text)
		cursor, _ = page["nextCursor"].(string)
		if pages == 1 {
			firstCursor = cursor
		}
		if page["hasMore"] != true {
			if pages < 2 {
				t.Fatalf("%d bytes of output came in one page", want.Len())
			}
			break
		}
		if pages > 10 {
			t.Fatal("the pages did not end")
		}
	}
	if got.String() != want.String() {
		t.Fatalf("the pages joined to %d bytes, want the %d bytes of output", got.Len(), want.Len())
	}
	if end := read(cursor); end["output"] != "" || end["hasMore"] != false || end["nextCursor"] != cursor {
		t.Fatalf("a read at the end answered %#v", end)
	}
	h.app.appendBuildOutput(p, op, "tail\n")
	if tail := read(cursor); tail["output"] != "tail\n" || tail["reset"] != false {
		t.Fatalf("the read after new output answered %#v", tail)
	}

	for i := 0; i < buildOutputMaxLines; i++ {
		h.app.appendBuildOutput(p, op, "x\n")
	}
	trimmed := read(firstCursor)
	if text, _ := trimmed["output"].(string); trimmed["reset"] != true || !strings.HasPrefix(text, "x\n") {
		t.Fatalf("a cursor into dropped output answered reset %v with %.20q", trimmed["reset"], text)
	}
}

// TestIDEBuildConfigureAnswersWithTheValueCoreReadBack edits a declared option of the contract's
// instance-options fixture through the tool: the answer is the value and source Core read back
// from the stored documents, removing the override returns the option to its default, Core's
// refusal of a value is passed on, and an unknown option, an unknown instance or the open
// options dialog are refused before anything is stored.
func TestIDEBuildConfigureAnswersWithTheValueCoreReadBack(t *testing.T) {
	manifest, err := os.ReadFile(contractfixture.Path("fixtures/build-systems/build-instance-options.plugin.json"))
	if err != nil {
		t.Fatal(err)
	}
	h := newHarness(t, &testKernel{Client: core.NewClient()})
	p, conn := ideAPIProject(t, h)
	install := func() {
		t.Helper()
		// The edit detects the instances again; this project has no installed plugin, so the
		// test puts the fixture's instance back once that detection ended.
		awaitStateWithin(t, h, 10*time.Second, "the detection after the edit", func() bool { return !p.build.loading })
		h.settle()
		p.build.instances = []buildInstance{{
			BuildInstance: core.BuildInstance{ID: "cargo", BuildSystemID: "cargo", DisplayName: "Cargo", Root: "."},
			PluginID:      "dev.lithe.fixture.build-instance-options",
			Manifest:      manifest,
		}}
	}
	configure := func(option string, value any) any {
		t.Helper()
		install()
		return ideAPICall(t, h, conn, "lithe_build_configure", map[string]any{"instanceID": "cargo", "optionID": option, "value": value})
	}
	stored := func() bool {
		t.Helper()
		all := map[string]json.RawMessage{}
		if _, err := h.store.Load(buildLocalOptionsFile, &all); err != nil {
			t.Fatal(err)
		}
		_, ok := all[p.root]
		return ok && strings.Contains(string(all[p.root]), "release")
	}

	set := ideAPIObject(t, configure("release", true))
	if set["value"] != true || set["source"] != "user" || set["reloading"] != true || set["optionID"] != "release" {
		t.Fatalf("setting the option answered %#v", set)
	}
	if !stored() {
		t.Fatal("the edit did not store the project's local override")
	}
	if code := ideAPIFailureCode(configure("release", "sometimes")); code != "INVALID_ARGUMENTS" {
		t.Fatalf("a value Core refuses answered %q, want INVALID_ARGUMENTS", code)
	}
	cleared := ideAPIObject(t, configure("release", nil))
	if cleared["source"] == "user" || cleared["value"] == true {
		t.Fatalf("removing the override answered %#v", cleared)
	}
	if stored() {
		t.Fatal("removing the override kept it stored")
	}
	if code := ideAPIFailureCode(configure("nonexistent", true)); code != "NOT_FOUND" {
		t.Fatalf("an unknown option answered %q, want NOT_FOUND", code)
	}
	install()
	if code := ideAPIFailureCode(ideAPICall(t, h, conn, "lithe_build_configure", map[string]any{"instanceID": "gradle", "optionID": "release", "value": true})); code != "NOT_FOUND" {
		t.Fatalf("an unknown instance answered %q, want NOT_FOUND", code)
	}
	p.build.options.open = true
	if code := ideAPIFailureCode(ideAPICall(t, h, conn, "lithe_build_configure", map[string]any{"instanceID": "cargo", "optionID": "release", "value": true})); code != "BUSY" {
		t.Fatalf("an edit while the options dialog is open answered %q, want BUSY", code)
	}
	p.build.options.open = false
}
