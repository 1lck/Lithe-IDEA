//go:build !windows

package localshell

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/1lck/Lithe-IDEA/desktop/internal/term"
)

// integrated is a shell and the terminal reading its output, paired the way the
// terminal view pairs them. What the shell reported is read from its output as
// it came: the OSC 133 markers that carry this start's token, ended with BEL as
// the scripts end them.
type integrated struct {
	t      *testing.T
	shell  *Shell
	wakes  chan struct{}
	screen *term.Terminal
	token  string
	output string
}

func startIntegrated(t *testing.T, config Config, token string) *integrated {
	t.Helper()
	config.Cols, config.Rows = 120, 24
	shell, wakes := start(t, config)
	s := &integrated{t: t, shell: shell, wakes: wakes, screen: term.New(120, 24, 0), token: token}
	s.screen.SetPromptToken(token)
	return s
}

// marks counts the shell's OSC 133 markers of kind ("A", "B" or "C") so far.
func (s *integrated) marks(kind string) int {
	return strings.Count(s.output, "\x1b]133;"+kind+";motty="+s.token+"\a")
}

// ready counts the prompts the shell has finished drawing (OSC 133 B).
func (s *integrated) ready() int { return s.marks("B") }

// starts counts the commands the shell has reported starting (OSC 133 C).
func (s *integrated) starts() int { return s.marks("C") }

// lastExit is the status of the last command end the shell reported (OSC 133
// D), or -1 before the first.
func (s *integrated) lastExit() int {
	ends := regexp.MustCompile("\x1b\\]133;D;([0-9]+);motty="+regexp.QuoteMeta(s.token)+"\a").FindAllStringSubmatch(s.output, -1)
	if len(ends) == 0 {
		return -1
	}
	status, err := strconv.Atoi(ends[len(ends)-1][1])
	if err != nil {
		s.t.Fatalf("command end status %q: %v", ends[len(ends)-1][1], err)
	}
	return status
}

// await feeds the shell's output to the terminal until done holds. The
// terminal's state changes only with output, and every output wakes the wait.
func (s *integrated) await(what string, done func() bool) {
	s.awaitWithin(what, 10*time.Second, done)
}

// awaitWithin uses the caller's bounded deadline for the first cold shell
// startup under full-CI load, without changing the interactive command budget.
func (s *integrated) awaitWithin(what string, timeout time.Duration, done func() bool) {
	s.t.Helper()
	deadline := time.NewTimer(timeout)
	defer deadline.Stop()
	for {
		data := s.shell.Drain(nil)
		s.output += string(data)
		_, _ = s.screen.Write(data)
		if done() {
			return
		}
		select {
		case <-s.wakes:
		case <-deadline.C:
			s.t.Fatalf("waiting for %s (ready=%d starts=%d): %q", what, s.ready(), s.starts(), s.output)
		}
	}
}

// run types input and waits for the prompts that follow it and for text.
func (s *integrated) run(input string, prompts int, text string) {
	s.t.Helper()
	before := s.ready()
	s.shell.Write([]byte(input))
	s.await(strconv.Quote(input), func() bool { return s.ready() >= before+prompts && strings.Contains(s.output, text) })
}

// exit types command and waits for the shell to end with status.
func (s *integrated) exit(command string, status int) {
	s.t.Helper()
	s.shell.Write([]byte(command))
	select {
	case <-s.shell.Done():
	case <-time.After(10 * time.Second):
		s.t.Fatalf("the shell did not exit after %q: %q", command, s.output)
	}
	if s.shell.ExitStatus() != status {
		s.t.Fatalf("exit status = %d, want %d", s.shell.ExitStatus(), status)
	}
}

func emptyDirectory(t *testing.T, dir string) {
	t.Helper()
	if files, err := os.ReadDir(dir); err != nil || len(files) != 0 {
		t.Fatalf("session files leaked into %s: %v, %v", dir, files, err)
	}
}

// processUmask is the file mode mask a shell started by this process inherits.
func processUmask(t *testing.T) os.FileMode {
	t.Helper()
	out, err := exec.Command("/bin/sh", "-c", "umask").Output()
	if err != nil {
		t.Fatal(err)
	}
	mask, err := strconv.ParseUint(strings.TrimSpace(string(out)), 8, 32)
	if err != nil {
		t.Fatalf("umask printed %q: %v", out, err)
	}
	return os.FileMode(mask)
}

func TestIntegrationStartsOnlyBashAndZshWithATokenTheScriptCanCarry(t *testing.T) {
	for _, shell := range []string{"", "bash", "zsh", "/bin/sh", "/usr/bin/fish", "/bin/bash\n", "/bin/bash;touch /tmp/no"} {
		if args := integrationArgs(shell, "token", "/dir"); args != nil {
			t.Errorf("unsupported shell %q started through the integration", shell)
		}
	}
	for _, token := range []string{"", "a;b", "a b", "a'b", "a$b", strings.Repeat("a", 129)} {
		if args := integrationArgs("/bin/zsh", token, "/dir"); args != nil {
			t.Errorf("token %q was put into the script", token)
		}
	}
	args := integrationArgs("/usr/local/bin/bash", "Tok-en_2", "/private dir")
	if len(args) != 6 || args[0] != "-c" || args[2] != "sh" || args[3] != "/usr/local/bin/bash" || args[4] != "" || args[5] != "/private dir" {
		t.Fatalf("args = %q", args)
	}
	if !strings.Contains(args[1], `exec "$1"`) || strings.Contains(args[1], "mktemp") {
		t.Fatalf("sh does not become the shell in the directory it was given: %q", args[1])
	}
	if !strings.Contains(args[1], ";motty=Tok-en_2") || strings.Contains(args[1], "__MOTTY_SUFFIX__") {
		t.Fatalf("the script does not carry the token: %q", args[1])
	}
}

// A shell started without Args and with a token reports its prompt and the start
// and status of every command, runs the user's own startup and prompt hooks, and
// is still idle at its prompt and busy while a command runs.
func TestIntegratedShellReportsPromptsAndCommands(t *testing.T) {
	for _, name := range []string{"bash", "zsh"} {
		t.Run(name, func(t *testing.T) {
			program, err := exec.LookPath(name)
			if err != nil {
				t.Skipf("%s unavailable: %v", name, err)
			}
			home, runtimeDir := filepath.Join(t.TempDir(), "home %#;中文"), t.TempDir()
			target := filepath.Join(home, "a b%'#;$()", "café")
			if err := os.MkdirAll(target, 0o700); err != nil {
				t.Fatal(err)
			}
			profile := "printf 'user-profile-loaded\\n'\n"
			file := ".bash_profile"
			if name == "bash" {
				profile += "PS1='user-prompt> '; PROMPT_COMMAND='printf \"user-hook\\n\"'\n"
			} else {
				file = ".zshrc"
				profile += "PS1='user-prompt> '; precmd() { printf 'user-hook\\n'; }\n"
			}
			profilePath := filepath.Join(home, file)
			if err := os.WriteFile(profilePath, []byte(profile), 0o600); err != nil {
				t.Fatal(err)
			}
			s := startIntegrated(t, Config{
				Shell: program, PromptToken: "pty-test-token", Dir: home, Unset: []string{"TERM_PROGRAM"},
				Env: []string{"HOME=" + home, "ZDOTDIR=" + home, "SHELL=" + program, "TMPDIR=" + runtimeDir, "LANG=en_US.UTF-8"},
			}, "pty-test-token")
			s.await("the first prompt", func() bool { return s.ready() > 0 })
			// The shell removes its private startup files once it has read them.
			emptyDirectory(t, runtimeDir)
			// Every Bash and Zsh reports command starts: PS0 or preexec, or a
			// DEBUG trap before Bash 4.4, announced once at start-up.
			if s.starts() == 0 || !s.screen.CommandReporting() {
				t.Fatalf("the shell did not announce command-start reporting: %q", s.output)
			}
			busyWithin(t, s.shell, false)

			s.run("false\r", 1, "")
			if s.lastExit() != 1 {
				t.Fatalf("false exit status = %d; output %q", s.lastExit(), s.output)
			}
			s.run("true\r", 1, "")
			if s.lastExit() != 0 {
				t.Fatalf("true exit status = %d", s.lastExit())
			}
			if !strings.Contains(s.output, "user-profile-loaded") || !strings.Contains(s.output, "user-hook") {
				t.Fatalf("the user's profile or prompt hook was lost: %q", s.output)
			}

			// The private startup's umask 077 is not left to the user's shell.
			s.run(": > \"$HOME/mask-file\"; mkdir \"$HOME/mask-dir\"; printf 'mask-check-%s\\n' done\r", 1, "mask-check-done\r\n")
			mask := processUmask(t)
			for name, mode := range map[string]os.FileMode{"mask-file": 0o666 &^ mask, "mask-dir": 0o777 &^ mask} {
				info, err := os.Stat(filepath.Join(home, name))
				if err != nil || info.Mode().Perm() != mode {
					t.Fatalf("the shell's umask changed for %s: info=%v, err=%v; want %04o", name, info, err, mode)
				}
			}

			startsBefore := s.starts()
			s.run("cd -- '"+strings.ReplaceAll(target, "'", "'\\''")+"' && printf 'in=%s\\n' \"$PWD\"\r", 1, "in="+target+"\r\n")
			if s.starts() <= startsBefore {
				t.Fatal("cd was not preceded by a command-start report")
			}
			if strings.Count(s.output, "user-hook\r\n") < 2 {
				t.Fatalf("the user's prompt hook was overwritten: %q", s.output)
			}
			if name == "zsh" {
				s.run("printf 'zdot=%s\\n' \"$ZDOTDIR\"\r", 1, "zdot="+home+"\r\n")
			}

			// The shell's own prompt is idle, and a command it runs in the
			// foreground is busy.
			s.shell.Write([]byte("sleep 30\r"))
			busyWithin(t, s.shell, true)
			before := s.ready()
			s.shell.Write([]byte{0x03})
			s.await("the prompt after Ctrl+C", func() bool { return s.ready() > before })
			busyWithin(t, s.shell, false)

			s.exit("exit 7\r", 7)
			if data, err := os.ReadFile(profilePath); err != nil || string(data) != profile {
				t.Fatalf("the profile changed: %q, %v", data, err)
			}
			emptyDirectory(t, runtimeDir)
		})
	}
}

// sh becomes the user's shell, so closing the terminal hangs up the shell
// itself, which passes the hangup on to its jobs, as it does unintegrated.
func TestClosingAnIntegratedShellHangsUpTheShellAndItsJobs(t *testing.T) {
	for _, name := range []string{"bash", "zsh", "/bin/bash"} {
		t.Run(name, func(t *testing.T) {
			s := startHangupShell(t, name, nil)
			s.run("sleep 300 & echo job=$!\r", 1, "\r\njob=")
			job := jobOf(t, s)
			closeAndAwaitEnd(t, s.shell)
			awaitProcessEnd(t, job)
		})
	}
}

// Bash passes a hangup on to its jobs only while it counts as interactive, and
// it does not while it runs PROMPT_COMMAND, which the integration uses; Zsh
// misses a job it is still starting. A shell closed between a command and its
// next prompt is therefore hung up once it shows the prompt. The test closes as
// soon as the command has printed, before the prompt; the slow prompt command
// keeps Bash in PROMPT_COMMAND for long after.
func TestClosingAnIntegratedShellRightAfterACommandHangsUpItsJobs(t *testing.T) {
	for _, test := range []struct {
		name, shell string
		env         []string
	}{
		{"bash", "bash", nil},
		{"zsh", "zsh", nil},
		{"/bin/bash", "/bin/bash", nil},
		{"bash with a slow prompt command", "bash", []string{"PROMPT_COMMAND=sleep 0.3"}},
	} {
		t.Run(test.name, func(t *testing.T) {
			s := startHangupShell(t, test.shell, test.env)
			s.shell.Write([]byte("sleep 300 & echo job=$!\r"))
			s.await("the job's pid", func() bool { return jobPattern.MatchString(s.output) })
			job := jobOf(t, s)
			closeAndAwaitEnd(t, s.shell)
			awaitProcessEnd(t, job)
		})
	}
}

// A closed shell that does not get back to its prompt, here one busy in a loop
// of builtins, is still hung up, after promptGrace.
func TestClosingAnIntegratedShellThatNeverPromptsStillEndsIt(t *testing.T) {
	for _, name := range []string{"bash", "zsh"} {
		t.Run(name, func(t *testing.T) {
			s := startHangupShell(t, name, nil)
			starts := s.starts()
			s.shell.Write([]byte("while :; do :; done\r"))
			s.await("the loop's start", func() bool { return s.starts() > starts })
			closeAndAwaitEnd(t, s.shell)
		})
	}
}

// startHangupShell starts the integrated shell name in an empty home, with env
// added, and waits for its first prompt.
func startHangupShell(t *testing.T, name string, env []string) *integrated {
	t.Helper()
	program, err := exec.LookPath(name)
	if err != nil {
		t.Skipf("%s unavailable: %v", name, err)
	}
	home, runtimeDir := t.TempDir(), t.TempDir()
	s := startIntegrated(t, Config{
		Shell: program, PromptToken: "hangup-token", Dir: home, Unset: []string{"TERM_PROGRAM"},
		Env: append([]string{"HOME=" + home, "ZDOTDIR=" + home, "SHELL=" + program, "TMPDIR=" + runtimeDir, "LANG=en_US.UTF-8"}, env...),
	}, "hangup-token")
	s.await("the first prompt", func() bool { return s.ready() > 0 })
	return s
}

var jobPattern = regexp.MustCompile(`\r\njob=(\d+)\r\n`)

// jobOf is the pid the shell printed as job=<pid>; the job is killed when the test ends.
func jobOf(t *testing.T, s *integrated) int {
	t.Helper()
	match := jobPattern.FindStringSubmatch(s.output)
	if match == nil {
		t.Fatalf("no job pid in %q", s.output)
	}
	job, _ := strconv.Atoi(match[1])
	t.Cleanup(func() { _ = syscall.Kill(job, syscall.SIGKILL) })
	return job
}

// closeAndAwaitEnd closes shell and waits for it to end. Close hangs a settling
// shell up within promptGrace and kills one that outlives killGrace after that.
func closeAndAwaitEnd(t *testing.T, shell *Shell) {
	t.Helper()
	shell.Close()
	select {
	case <-shell.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("closing did not end the shell")
	}
}

// awaitProcessEnd waits for the process pid, which is not this test's child, to end.
func awaitProcessEnd(t *testing.T, pid int) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !errors.Is(syscall.Kill(pid, 0), syscall.ESRCH) {
		if time.Now().After(deadline) {
			t.Fatalf("the shell's job %d outlived the closed terminal by 5s", pid)
		}
		// test-stability: allow(go-real-sleep) reason: the end of a process that is not this test's child has no event to wait on.
		time.Sleep(10 * time.Millisecond)
	}
}

// A shell closed while its startup files still run never reaches the point
// where it removes its private startup directory, and one that ignores the
// hangup is killed. The shell is the process the terminal started, so the kill
// ends it, and the directory goes with it.
func TestClosingAShellDuringItsStartupRemovesItsPrivateDirectory(t *testing.T) {
	for _, test := range []struct{ name, file string }{{"bash", ".bash_profile"}, {"zsh", ".zshrc"}} {
		t.Run(test.name, func(t *testing.T) {
			program, err := exec.LookPath(test.name)
			if err != nil {
				t.Skipf("%s unavailable: %v", test.name, err)
			}
			home, runtimeDir := t.TempDir(), t.TempDir()
			// The loop is bounded so that a shell the kill missed still ends.
			startup := "trap '' HUP\nprintf 'startup-pid=%s.\\n' \"$$\"\nwhile (( SECONDS < 10 )); do :; done\n"
			if err := os.WriteFile(filepath.Join(home, test.file), []byte(startup), 0o600); err != nil {
				t.Fatal(err)
			}
			s := startIntegrated(t, Config{
				Shell: program, PromptToken: "startup-close-token", Dir: home, Unset: []string{"TERM_PROGRAM"},
				Env: []string{"HOME=" + home, "ZDOTDIR=" + home, "SHELL=" + program, "TMPDIR=" + runtimeDir, "LANG=en_US.UTF-8"},
			}, "startup-close-token")
			pid := regexp.MustCompile(`startup-pid=(\d+)\.`)
			s.await("the startup files to run", func() bool { return pid.MatchString(s.output) })
			shell, _ := strconv.Atoi(pid.FindStringSubmatch(s.output)[1])
			t.Cleanup(func() { _ = syscall.Kill(shell, syscall.SIGKILL) })
			if files, err := os.ReadDir(runtimeDir); err != nil || len(files) != 1 {
				t.Fatalf("the startup directory is not there while the startup runs: %v, %v", files, err)
			}

			s.shell.Close()
			select {
			case <-s.shell.Done():
			case <-time.After(5 * time.Second):
				t.Fatal("closing did not end the shell")
			}
			if err := syscall.Kill(shell, 0); !errors.Is(err, syscall.ESRCH) {
				t.Fatalf("the shell %d outlived the closed terminal: %v", shell, err)
			}
			emptyDirectory(t, runtimeDir)
		})
	}
}

// Bash before 4.4 has no PS0, so it reports the start of a command line from a
// DEBUG trap. The trap path is forced here so that a current Bash exercises it.
// Each line typed must be announced once, nothing else may be, and the user's
// own DEBUG trap and prompt command must still run.
func TestIntegratedBashDebugTrapReportsEachCommandLineOnce(t *testing.T) {
	program, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash unavailable")
	}
	for _, profile := range commandStartProfiles {
		t.Run(profile.name, func(t *testing.T) {
			profile.require(t, program)
			checkCommandStartReports(t, func(env []string, runtimeDir string) Config {
				dir, err := os.MkdirTemp(runtimeDir, "motty-shell.")
				if err != nil {
					t.Fatal(err)
				}
				return Config{Shell: "/bin/sh", Args: integrationArgsWith(program, true, "debug-trap-token", dir), Env: env}
			}, program, profile.text)
		})
	}
}

// Bash 4.4 and later report the start of a command line from PS0. The user's
// DEBUG trap prints BASH_COMMAND, so a marker spelled out in the text of a
// startup command would be counted as a report.
func TestIntegratedBashReportsEachCommandLineOnce(t *testing.T) {
	program, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash unavailable")
	}
	if !bashAtLeast(t, program, 4, 4) {
		t.Skipf("%s has no PS0", program)
	}
	for _, profile := range commandStartProfiles {
		t.Run(profile.name, func(t *testing.T) {
			profile.require(t, program)
			checkCommandStartReports(t, func(env []string, _ string) Config {
				return Config{Shell: program, PromptToken: "debug-trap-token", Env: env}
			}, program, profile.text)
		})
	}
}

// The Bash at /bin/bash is the one a user who chose Bash most often gets: 3.2
// on macOS, which takes the DEBUG trap path by itself, and a current one on
// Linux. It starts here the way the terminal starts it.
func TestIntegratedSystemBashReportsEachCommandLineOnce(t *testing.T) {
	if _, err := os.Stat("/bin/bash"); err != nil {
		t.Skip("no /bin/bash")
	}
	checkCommandStartReports(t, func(env []string, _ string) Config {
		return Config{Shell: "/bin/bash", PromptToken: "debug-trap-token", Env: env}
	}, "/bin/bash", commandStartProfiles[0].text)
}

// commandStartProfiles are the user's login profiles the command-start tests
// run under. Each sets a prompt, a prompt command and a DEBUG trap of the
// user's own.
var commandStartProfiles = []struct {
	name, text string
	// require skips a profile the Bash at program cannot run as written.
	require func(t *testing.T, program string)
}{
	{"string prompt command", commandStartProfile, func(*testing.T, string) {}},
	// systemd's /etc/profile.d/80-systemd-osc-context.sh (systemd 257 and
	// later, as on Ubuntu 26.04) turns PROMPT_COMMAND into an array, leaving
	// element 0 for a profile that assigns a string, and puts a command
	// substitution in front of PS0. Bash runs an array PROMPT_COMMAND from 5.1.
	{"array prompt command", "[ -n \"$(declare -p PROMPT_COMMAND 2>/dev/null)\" ] || PROMPT_COMMAND+=('')\n" +
		"__system_hook() { printf 'system-%s\\n' hook; }\nPROMPT_COMMAND+=(__system_hook)\n" +
		"__system_ps0() { printf 'system-%s' ps0; }\nPS0='$(__system_ps0)'\"${PS0:-}\"\n" + commandStartProfile,
		func(t *testing.T, program string) {
			if !bashAtLeast(t, program, 5, 1) {
				t.Skipf("%s runs only the first element of an array PROMPT_COMMAND", program)
			}
		}},
}

const commandStartProfile = "PS1='user-prompt> '\nPROMPT_COMMAND='printf \"user-hook\\n\"'\ntrap 'printf \"user-debug:%s\\n\" \"$BASH_COMMAND\"' DEBUG\n"

// bashAtLeast reports whether the Bash at program is at least major.minor.
func bashAtLeast(t *testing.T, program string, major, minor int) bool {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, program, "-c", `echo "${BASH_VERSINFO[0]} ${BASH_VERSINFO[1]}"`).Output()
	if err != nil {
		t.Fatalf("read the version of %s: %v", program, err)
	}
	var gotMajor, gotMinor int
	if _, err := fmt.Sscan(string(out), &gotMajor, &gotMinor); err != nil {
		t.Fatalf("the version of %s, %q: %v", program, out, err)
	}
	return gotMajor > major || gotMajor == major && gotMinor >= minor
}

func checkCommandStartReports(t *testing.T, config func(env []string, runtimeDir string) Config, program, profile string) {
	t.Helper()
	home, runtimeDir := t.TempDir(), t.TempDir()
	if err := os.WriteFile(filepath.Join(home, ".bash_profile"), []byte(profile), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := config([]string{"HOME=" + home, "SHELL=" + program, "TMPDIR=" + runtimeDir, "LANG=en_US.UTF-8"}, runtimeDir)
	cfg.Dir, cfg.Unset = home, []string{"TERM_PROGRAM"}
	s := startIntegrated(t, cfg, "debug-trap-token")
	s.await("the first prompt", func() bool { return s.ready() > 0 })
	if s.starts() != 1 {
		t.Fatalf("the shell did not announce command-start reporting once: %d", s.starts())
	}
	// A stray report after a step is counted in the next one, so every step,
	// the last included, is followed by another.
	for _, step := range []struct {
		name, input, text string
		prompts, starts   int
	}{
		{"one command", "echo marker-one\r", "marker-one\r\n", 1, 1},
		{"an empty line", "\r", "", 1, 0},
		{"typeahead", "echo marker-two\recho marker-three\r", "marker-three\r\n", 2, 2},
		{"a compound command", "for i in 1 2 3; do echo loop$i; done\r", "loop3\r\n", 1, 1},
		{"a pipeline", "echo piped | cat\r", "piped\r\n", 1, 1},
		{"a failing command", "false\r", "", 1, 1},
		{"the status it left", "echo status=$?\r", "status=1\r\n", 1, 1},
		{"one more", "echo marker-four\r", "marker-four\r\n", 1, 1},
	} {
		before := s.starts()
		s.run(step.input, step.prompts, step.text)
		if s.starts()-before != step.starts {
			t.Fatalf("%s: %d command starts reported, want %d; output %q", step.name, s.starts()-before, step.starts, s.output)
		}
	}
	if !strings.Contains(s.output, "user-debug:echo marker-one\r\n") {
		t.Fatalf("the user's DEBUG trap did not run with its BASH_COMMAND: %q", s.output)
	}
	if !strings.Contains(s.output, "user-hook\r\n") {
		t.Fatalf("the user's PROMPT_COMMAND was lost: %q", s.output)
	}
	// The profile prints these through a format, so that its own text, which
	// the user's DEBUG trap echoes, does not contain them.
	for _, hook := range []string{"system-hook\r\n", "system-ps0"} {
		if strings.Contains(profile, "__system_") && !strings.Contains(s.output, hook) {
			t.Fatalf("the profile's %q did not run: %q", hook, s.output)
		}
	}
	s.exit("exit 5\r", 5)
	emptyDirectory(t, runtimeDir)
}

// A login shell reads ~/.bashrc only through the login profile that sources
// it. The startup shim must run the user's startup files the way that login
// shell does: sourcing ~/.bashrc after the profile already did would run the
// user's interactive startup twice on the distributions whose profiles source it.
func TestIntegratedBashStartupMatchesALoginShell(t *testing.T) {
	program, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("bash unavailable")
	}
	for _, test := range []struct {
		name, profile string
		want          int
	}{
		// The Debian, Ubuntu and RHEL default: the login profile sources
		// ~/.bashrc itself.
		{"login-profile-sources-bashrc", "if [ -r \"$HOME/.bashrc\" ]; then . \"$HOME/.bashrc\"; fi\n", 1},
		// No login profile: a login shell never reads ~/.bashrc.
		{"bashrc-only", "", 0},
	} {
		t.Run(test.name, func(t *testing.T) {
			home, runtimeDir := t.TempDir(), t.TempDir()
			if err := os.WriteFile(filepath.Join(home, ".bashrc"), []byte("printf 'user-bashrc\\n'\n"), 0o600); err != nil {
				t.Fatal(err)
			}
			if test.profile != "" {
				if err := os.WriteFile(filepath.Join(home, ".bash_profile"), []byte(test.profile), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			env := []string{"HOME=" + home, "SHELL=" + program, "TMPDIR=" + runtimeDir, "LANG=en_US.UTF-8"}
			// A shell reads a typed line only after its startup files have run,
			// so all their output comes before the line's.
			read := func(config Config) string {
				t.Helper()
				s := startIntegrated(t, config, "startup-token")
				s.run("echo startup-$((6*7))\r", 0, "startup-42\r\n")
				s.exit("exit 0\r", 0)
				return s.output
			}
			login := read(Config{Shell: program, Args: []string{"-l", "-i"}, Dir: home, Env: env, Unset: []string{"TERM_PROGRAM"}})
			shim := read(Config{Shell: program, PromptToken: "startup-token", Dir: home, Env: env, Unset: []string{"TERM_PROGRAM"}})
			if runs := strings.Count(login, "user-bashrc"); runs != test.want {
				t.Fatalf("the fixture's login shell ran ~/.bashrc %d time(s), want %d: %q", runs, test.want, login)
			}
			if runs := strings.Count(shim, "user-bashrc"); runs != test.want {
				t.Fatalf("the startup shim ran ~/.bashrc %d time(s); a login shell runs it %d time(s): %q", runs, test.want, shim)
			}
			emptyDirectory(t, runtimeDir)
		})
	}
}

// Zsh is started with a private ZDOTDIR, which /etc/zshrc may take for the
// place of the history file. The history must stay where an ordinary login
// shell keeps it and carry over from one session to the next.
func TestIntegratedZshHistorySurvivesSessions(t *testing.T) {
	program, err := exec.LookPath("zsh")
	if err != nil {
		t.Skipf("zsh unavailable: %v", err)
	}
	for _, test := range []struct{ name, location, rc, login string }{
		{name: "default"},
		{name: "custom-zdotdir", location: "environment"},
		{name: "zshenv-zdotdir", location: ".zshenv"},
		{name: "custom-history", rc: `HISTFILE="$HOME/custom history"`},
		{name: "login-history", login: `HISTFILE="$HOME/login history"`},
		{name: "unset-history", rc: "unset HISTFILE\nsetopt NO_UNSET"},
		{name: "empty-history", rc: "HISTFILE="},
	} {
		t.Run(test.name, func(t *testing.T) {
			home, runtimeDir := t.TempDir(), t.TempDir()
			env := []string{"HOME=" + home, "SHELL=" + program, "TMPDIR=" + runtimeDir, "TERM=xterm-256color", "LANG=en_US.UTF-8"}
			unset := []string{"ZDOTDIR", "TERM_PROGRAM"}
			dotdir := home
			if test.location != "" {
				dotdir = filepath.Join(home, "zsh files %'#")
				if err := os.Mkdir(dotdir, 0o700); err != nil {
					t.Fatal(err)
				}
				if test.location == "environment" {
					env, unset = append(env, "ZDOTDIR="+dotdir), []string{"TERM_PROGRAM"}
				} else if err := os.WriteFile(filepath.Join(home, ".zshenv"), []byte("ZDOTDIR=\"$HOME/zsh files %'#\"\n"), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			profiles := map[string]string{
				".zshrc":  "_test_rc_histfile=${HISTFILE-}\nPS1='history-test> '\nHISTSIZE=200\nSAVEHIST=200\n" + test.rc + "\n",
				".zlogin": test.login + "\n",
			}
			for name, text := range profiles {
				if err := os.WriteFile(filepath.Join(dotdir, name), []byte(text), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			// Compare with an ordinary login shell on this machine, including
			// what the user's rc file saw before choosing its own history path.
			diagnostic := `printf '\036history=%s\037rc=%s\036' "${HISTFILE-}" "$_test_rc_histfile"`
			plain := exec.Command(program, "-lic", diagnostic)
			plain.Env = append(withoutVariables(os.Environ(), unset), env...)
			data, err := plain.CombinedOutput()
			if err != nil {
				t.Fatalf("ordinary zsh: %v: %q", err, data)
			}
			_, expected, ok := strings.Cut(string(data), "\x1ehistory=")
			if !ok {
				t.Fatalf("ordinary zsh did not report its history path: %q", data)
			}
			expected, _, ok = strings.Cut(expected, "\x1e")
			if !ok {
				t.Fatalf("incomplete history report: %q", data)
			}
			histfile, _, _ := strings.Cut(expected, "\x1frc=")
			for session := 0; session < 2; session++ {
				s := startIntegrated(t, Config{Shell: program, PromptToken: "history-token", Dir: home, Env: env, Unset: unset}, "history-token")
				run := func(input, want string) {
					t.Helper()
					// Only what follows the input counts: the prompt after it and want.
					s.output = ""
					s.shell.Write([]byte(input + "\r"))
					s.await("session "+strconv.Itoa(session)+": "+strconv.Quote(input), func() bool { return s.ready() > 0 && strings.Contains(s.output, want) })
				}
				s.await("the first prompt", func() bool { return s.ready() > 0 })
				if session == 1 && histfile != "" {
					run("\x1b[A", "\x1elithe-history-marker\x1f")
				}
				run(diagnostic, "\x1ehistory="+expected+"\x1e")
				if session == 0 {
					run(`printf '\036lithe-history-marker\037\n'`, "\x1elithe-history-marker\x1f")
					run("\x1b[A", "\x1elithe-history-marker\x1f")
				}
				// EOF saves history without adding an exit command for the next
				// session's Up key to recall instead of the marker.
				s.exit("\x04", 0)
				if histfile != "" {
					data, err := os.ReadFile(histfile)
					if err != nil || !strings.Contains(string(data), "lithe-history-marker") {
						t.Fatalf("history was not saved to %q: %q, %v", histfile, data, err)
					}
				}
			}
			for name, want := range profiles {
				if data, err := os.ReadFile(filepath.Join(dotdir, name)); err != nil || string(data) != want {
					t.Fatalf("profile %s changed: %q, %v", name, data, err)
				}
			}
			emptyDirectory(t, runtimeDir)
		})
	}
}

// An unsupported shell, a token the script cannot carry and an explicit
// command all start the shell as itself, with no report.
func TestShellsTheIntegrationDoesNotCoverStartAsThemselves(t *testing.T) {
	for name, config := range map[string]Config{
		"sh":           {Shell: "/bin/sh", PromptToken: "plain-token"},
		"a bad token":  {Shell: "/bin/sh", PromptToken: "a;b"},
		"command args": {Shell: "/bin/sh", Args: []string{"-i"}, PromptToken: "plain-token"},
	} {
		t.Run(name, func(t *testing.T) {
			s := startIntegrated(t, config, "plain-token")
			s.run("echo plain-$((6*7))\n", 0, "plain-42")
			if s.ready() != 0 || s.starts() != 0 || s.screen.CommandReporting() {
				t.Fatalf("a shell outside the integration reported: ready=%d starts=%d: %q", s.ready(), s.starts(), s.output)
			}
		})
	}
}
