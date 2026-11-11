//go:build !windows

package loginenv

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"strings"
	"time"
)

// loginEnvironmentTimeout bounds the shell that reports the environment. A profile that
// waits on input or runs slowly must not hold up the first launch for longer than this.
const loginEnvironmentTimeout = 5 * time.Second

// marker separates the shell's own output, such as a profile's greeting, from the
// environment that follows it.
const marker = "LITHE-LOGIN-ENV"

func captureLoginEnvironment() map[string]string {
	shell := os.Getenv("SHELL")
	if shell == "" {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), loginEnvironmentTimeout)
	defer cancel()
	command := exec.CommandContext(ctx, shell, "-l", "-i", "-c", `printf '\0`+marker+`\0'; env -0`)
	command.WaitDelay = time.Second
	var output bytes.Buffer
	command.Stdout = &output
	if err := command.Run(); err != nil {
		return nil
	}
	data := output.String()
	index := strings.LastIndex(data, "\x00"+marker+"\x00")
	if index < 0 {
		return nil
	}
	environment := map[string]string{}
	for _, entry := range strings.Split(data[index+len(marker)+2:], "\x00") {
		key, value, found := strings.Cut(entry, "=")
		if found && key != "" {
			environment[key] = value
		}
	}
	return environment
}
