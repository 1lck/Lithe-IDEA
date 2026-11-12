package localshell

import (
	"bufio"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

func TestLocalCommandHelper(t *testing.T) {
	if os.Getenv("MOTTY_LOCAL_COMMAND_HELPER") != "1" {
		return
	}
	if os.Args[len(os.Args)-1] != "official-auth" {
		os.Exit(3)
	}
	fmt.Print("auth-prompt\r\n")
	line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	fmt.Printf("received:%s", line)
	os.Exit(0)
}
func TestLocalCommandUsesArgvAndInteractiveInput(t *testing.T) {
	exe, _ := os.Executable()
	shell, err := Start(Config{Shell: exe, Args: []string{"-test.run=^TestLocalCommandHelper$", "--", "official-auth"}, Env: []string{"MOTTY_LOCAL_COMMAND_HELPER=1"}, Cols: 80, Rows: 12})
	if err != nil {
		t.Fatal(err)
	}
	defer shell.Close()
	if !shell.Write([]byte("auth-code\r")) {
		t.Fatal("input refused")
	}
	if out := waitForExit(t, shell, 6*time.Second); !strings.Contains(out, "received:auth-code") {
		t.Fatalf("auth executable did not receive interactive input; it printed %q", out)
	}
}

// waitForExit waits, at most limit, for shell to end and returns everything it printed.
// Done closes only once the output is complete, so one Drain after it reads all of it.
func waitForExit(t *testing.T, shell *Shell, limit time.Duration) string {
	t.Helper()
	deadline := time.NewTimer(limit)
	defer deadline.Stop()
	select {
	case <-shell.Done():
	case <-deadline.C:
		t.Fatalf("shell did not end within %v; it printed %q so far", limit, shell.Drain(nil))
	}
	return string(shell.Drain(nil))
}
