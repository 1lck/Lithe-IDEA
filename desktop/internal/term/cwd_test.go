package term

import "testing"

func TestPromptReadyRequiresTheSessionToken(t *testing.T) {
	terminal := New(80, 24, 0)
	terminal.SetPromptToken("session-token")
	started, ready, commands := 0, 0, 0
	terminal.SetPromptStart(func() { started++ })
	terminal.SetPromptReady(func() { ready++ })
	terminal.SetCommandStart(func() { commands++ })
	terminal.Write([]byte("\x1b]133;A\a\x1b]133;B\a\x1b]133;A;motty=another-session\a\x1b]133;B;motty=another-session\a\x1b]133;C;motty=another-session\a"))
	if started != 0 || ready != 0 || commands != 0 {
		t.Fatal("a nested or unrelated shell authorized this session")
	}
	terminal.Write([]byte("\x1b]133;C;motty=session-token\a\x1b]133;A;motty=session-token\a\x1b]133;B;motty=session-token\a"))
	if started != 1 || ready != 1 || commands != 1 {
		t.Fatal("the owning shell was not recognized")
	}
}

func TestPromptReadyAcrossEverySplit(t *testing.T) {
	stream := []byte("\x1b]133;A\x07prompt\x1b]133;B\x1b\\")
	for cut := 0; cut <= len(stream); cut++ {
		terminal := New(80, 24, 0)
		ready, started := 0, 0
		terminal.SetPromptStart(func() { started++ })
		terminal.SetPromptReady(func() { ready++ })
		terminal.Write(stream[:cut])
		terminal.Write(stream[cut:])
		terminal.Write([]byte("\x1b]133;C\x07\x1b]133;B;untrusted\x07"))
		if ready != 1 || started != 1 {
			t.Fatalf("split %d: prompt-start/ready calls = %d/%d", cut, started, ready)
		}
	}
}

func TestWorkingDirectoryReportsAreReadAndDeduplicated(t *testing.T) {
	terminal := New(80, 24, 0)
	var seen []Cwd
	terminal.SetCwdChange(func(cwd Cwd) { seen = append(seen, cwd) })
	terminal.Write([]byte("\x1b]7;file://box/home/me/My%20Dir\x07"))
	terminal.Write([]byte("\x1b]7;file://box/home/me/My%20Dir\x1b\\")) // the same again, ended the other way
	terminal.Write([]byte("\x1b]7;file:///var/log\x07"))
	if len(seen) != 2 || seen[0] != (Cwd{Host: "box", Path: "/home/me/My Dir"}) || seen[1] != (Cwd{Path: "/var/log"}) {
		t.Fatalf("reports = %+v", seen)
	}
	if cwd, ok := terminal.WorkingDirectory(); !ok || cwd.Path != "/var/log" {
		t.Fatalf("WorkingDirectory = %+v, %v", cwd, ok)
	}
}

func TestWorkingDirectoryReportsAcrossEverySplit(t *testing.T) {
	stream := []byte("x\x1b]7;file://h/a/b%C3%A9\x07y")
	for cut := 1; cut < len(stream); cut++ {
		terminal := New(80, 24, 0)
		terminal.Write(stream[:cut])
		terminal.Write(stream[cut:])
		if cwd, ok := terminal.WorkingDirectory(); !ok || cwd.Path != "/a/bé" {
			t.Fatalf("cut at %d: %+v, %v", cut, cwd, ok)
		}
	}
}

func TestMalformedWorkingDirectoriesAreRefused(t *testing.T) {
	for _, report := range []string{
		"relative/path", "file://host", "file://host/bad%00path", "http://host/path", "file://host/%0a", "file://host/..%0d",
	} {
		terminal := New(80, 24, 0)
		terminal.Write([]byte("\x1b]7;" + report + "\x07"))
		if cwd, ok := terminal.WorkingDirectory(); ok {
			t.Errorf("%q was accepted as %+v", report, cwd)
		}
	}
}

func TestCommandFinishedValidatesStatusTokenAndSplitSequences(t *testing.T) {
	stream := []byte("\x1b]133;D;17;motty=session-token\a")
	for cut := 0; cut <= len(stream); cut++ {
		terminal := New(80, 24, 0)
		terminal.SetPromptToken("session-token")
		calls := 0
		terminal.SetCommandFinished(func(code int) {
			calls++
			if code != 17 {
				t.Fatalf("exit code %d", code)
			}
		})
		terminal.Write([]byte("\x1b]133;D;0\a\x1b]133;D;1;motty=foreign\a\x1b]133;D;-1;motty=session-token\a\x1b]133;D;256;motty=session-token\a\x1b]133;D;bad;motty=session-token\a"))
		terminal.Write(stream[:cut])
		terminal.Write(stream[cut:])
		if calls != 1 {
			t.Fatalf("split %d: %d calls", cut, calls)
		}
	}
}
