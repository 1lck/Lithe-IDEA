//go:build windows

package buildprocess

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"
)

const batchArgumentsMode = "LITHE_TEST_BATCH_ARGUMENTS"

// TestBatchArgumentsHelper prints the arguments after "--" as JSON. A test script passes its
// own arguments on to it with %*, as mvn.cmd passes them to Java.
func TestBatchArgumentsHelper(t *testing.T) {
	if os.Getenv(batchArgumentsMode) != "1" {
		return
	}
	index := slices.Index(os.Args, "--")
	if index < 0 {
		os.Exit(21)
	}
	data, err := json.Marshal(os.Args[index+1:])
	if err != nil {
		os.Exit(22)
	}
	fmt.Println(string(data))
	os.Exit(0)
}

// A script under a directory with a space receives every argument as written, including ones
// with spaces, quotes and cmd syntax, the way Maven's model load runs mvn.cmd (#2032).
func TestBatchFileUnderASpacedDirectoryReceivesItsArguments(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "Program Files", "tool home")
	if err := os.MkdirAll(filepath.Join(directory, "bin"), 0o755); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(directory, "bin", "tool.cmd")
	body := "@echo off\r\n\"" + os.Args[0] + "\" \"-test.run=^TestBatchArgumentsHelper$\" -- %*\r\nexit /b %ERRORLEVEL%\r\n"
	if err := os.WriteFile(script, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(t.TempDir(), "injected")
	arguments := []string{
		"-B",
		`-Dmaven.ext.class.path=C:\Users\me\AppData\Local\Lithe Desktop\plugins\x.jar`,
		"-Dlithe.modelOutput=" + filepath.Join(directory, "model out.json"),
		"",
		`trailing\`,
		`say "hi"`,
		"%" + batchArgumentsMode + "%",
		"a&echo injected>" + marker,
		`x|y<z>^`,
		"pre-clean",
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	var output strings.Builder
	var mu sync.Mutex
	process, err := Start(ctx, Spec{
		Executable:       script,
		Arguments:        arguments,
		WorkingDirectory: directory,
		Environment:      map[string]string{batchArgumentsMode: "1"},
	}, func(_ Stream, text string) {
		mu.Lock()
		output.WriteString(text)
		mu.Unlock()
	})
	if err != nil {
		t.Fatal(err)
	}
	waitErr := process.Wait()
	mu.Lock()
	text := output.String()
	mu.Unlock()
	if waitErr != nil {
		t.Fatalf("script failed: %v\n%s", waitErr, text)
	}
	var got []string
	if err := json.Unmarshal([]byte(strings.TrimSpace(text)), &got); err != nil {
		t.Fatalf("output is not the helper's JSON: %v\n%s", err, text)
	}
	if !slices.Equal(got, arguments) {
		t.Fatalf("arguments =\n%q\nwant\n%q", got, arguments)
	}
	if _, err := os.Stat(marker); err == nil {
		t.Fatal("an argument ran a command")
	}
}

// A command line Core planned reaches the process unchanged, Executable included, instead of
// one quoted from the arguments: cmd.exe runs a batch script the way Core wrote its line.
func TestCommandLineReachesTheProcessUnchanged(t *testing.T) {
	directory := filepath.Join(t.TempDir(), "spaced dir")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(directory, "run me.cmd")
	body := "@echo off\r\n\"" + os.Args[0] + "\" \"-test.run=^TestBatchArgumentsHelper$\" -- %*\r\nexit /b %ERRORLEVEL%\r\n"
	if err := os.WriteFile(script, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	cmd := filepath.Join(os.Getenv("SystemRoot"), "System32", "cmd.exe")
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	var output strings.Builder
	var mu sync.Mutex
	process, err := Start(ctx, Spec{
		Executable:       cmd,
		WorkingDirectory: directory,
		Environment:      map[string]string{batchArgumentsMode: "1"},
		CommandLine:      `cmd /d /s /c ""` + script + `" "a b" c"`,
	}, func(_ Stream, text string) {
		mu.Lock()
		output.WriteString(text)
		mu.Unlock()
	})
	if err != nil {
		t.Fatal(err)
	}
	waitErr := process.Wait()
	mu.Lock()
	text := output.String()
	mu.Unlock()
	if waitErr != nil {
		t.Fatalf("script failed: %v\n%s", waitErr, text)
	}
	var got []string
	if err := json.Unmarshal([]byte(strings.TrimSpace(text)), &got); err != nil {
		t.Fatalf("output is not the helper's JSON: %v\n%s", err, text)
	}
	if want := []string{"a b", "c"}; !slices.Equal(got, want) {
		t.Fatalf("arguments = %q, want %q", got, want)
	}
}
