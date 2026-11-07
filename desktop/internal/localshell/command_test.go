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
	var out []byte
	deadline := time.Now().Add(6 * time.Second)
	for time.Now().Before(deadline) {
		out = shell.Drain(out)
		if strings.Contains(string(out), "received:auth-code") {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("auth executable did not receive interactive input")
}
