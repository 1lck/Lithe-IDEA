package workbench

import (
	"errors"
	"strings"
	"testing"
)

// A failed model or dependency command's error ends with what the tool printed, so the user
// sees why it failed rather than only its exit status (#2032, #2027).
func TestBuildCommandFailureCarriesTheToolsExplanation(t *testing.T) {
	h, _, p := buildCommandHarness(t)
	installBuildTool(t)
	writeBuildCommandMarker(t, p.root, "explain")
	const explanation = "[ERROR] The JAVA_HOME environment variable is not defined correctly"
	check := func(name string, err error) {
		t.Helper()
		if err == nil {
			t.Fatalf("%s: a failed command loaded", name)
		}
		text := err.Error()
		// stdout and stderr are two pipes, so their lines may arrive in either order.
		if !strings.Contains(text, "exit status 1") || !strings.Contains(text, "\nScanning\n") || !strings.Contains(text, explanation) {
			t.Fatalf("%s: error = %q, want the exit status and the tool's last lines", name, text)
		}
		if strings.ContainsAny(text, "\x1b\r") {
			t.Fatalf("%s: error keeps terminal control characters: %q", name, text)
		}
		var launch *buildLaunchError
		if errors.As(err, &launch) {
			t.Fatalf("%s: a command that ran is a launch failure", name)
		}
	}
	_, err := h.app.commandModel(buildLoadContext(t, "action-61", pluginOperationWait), p, buildCommandInstance(".", false), h.app.kernel, nil, h.app.text.Build)
	check("model", err)
	kernel := h.app.kernel.(buildDependencyKernel)
	_, err = h.app.buildDependencyTree(buildLoadContext(t, "action-62", pluginOperationWait), p, buildCommandInstance(".", false), kernel, nil, false)
	check("dependencies", err)
}

func TestBuildOutputTailKeepsTheLastBoundedLines(t *testing.T) {
	var output strings.Builder
	for index := range buildFailureOutputLines + 5 {
		output.WriteString(strings.Repeat("x", index) + "line\r\n\r\n")
	}
	output.WriteString(strings.Repeat("界", buildFailureOutputLineBytes) + "\n\n")
	tail := buildOutputTail(output.String())
	lines := strings.Split(tail, "\n")
	if len(lines) != buildFailureOutputLines {
		t.Fatalf("tail has %d lines, want %d: %q", len(lines), buildFailureOutputLines, tail)
	}
	if !strings.HasSuffix(lines[len(lines)-2], "xline") || strings.HasPrefix(lines[0], "line") {
		t.Fatalf("tail is not the last lines in order: %q", lines)
	}
	last := lines[len(lines)-1]
	if len(last) > buildFailureOutputLineBytes+len("…") || !strings.HasSuffix(last, "…") || !strings.HasPrefix(last, "界") {
		t.Fatalf("long line = %q, want it cut at a character boundary", last)
	}
	if got := withBuildOutput(errors.New("exit status 2"), " \n\r\n"); got.Error() != "exit status 2" {
		t.Fatalf("a failure without output = %q", got)
	}
	if got := withBuildOutput(nil, "printed"); got != nil {
		t.Fatalf("a success became %v", got)
	}
}
