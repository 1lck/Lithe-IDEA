package buildprocess

import (
	"errors"
	"testing"
)

func TestBatchCommandLineQuotesTheWholeLineOnce(t *testing.T) {
	// The shape of Maven's model load (#2032): a script and an argument that both hold a space.
	line, err := batchCommandLine(`C:\Program Files\maven\bin\mvn.cmd`, []string{
		"-B", `-Dmaven.ext.class.path=C:\Users\me\AppData\Local\Lithe Desktop\x.jar`, "pre-clean",
	})
	if err != nil {
		t.Fatal(err)
	}
	want := `cmd.exe /e:ON /v:OFF /d /c ""C:\Program Files\maven\bin\mvn.cmd" -B "-Dmaven.ext.class.path=C:\Users\me\AppData\Local\Lithe Desktop\x.jar" pre-clean"`
	if line != want {
		t.Fatalf("line =\n%s\nwant\n%s", line, want)
	}
}

func TestBatchArgumentsCannotReachCmdSyntax(t *testing.T) {
	for _, tc := range []struct{ argument, want string }{
		{"plain-arg_1.0", `plain-arg_1.0`},
		{"", `""`},
		{`trailing\`, `"trailing\\"`},
		{`a&b`, `"a&b"`},
		{`x|y<z>^`, `"x|y<z>^"`},
		{`%PATH%`, `"%%cd:~,%PATH%%cd:~,%"`},
		{`say "hi"`, `"say ""hi"""`},
		{`back\"slash`, `"back\\""slash"`},
		{`(group)!`, `"(group)!"`},
		{`ünïcode`, `ünïcode`},
	} {
		line, err := batchCommandLine(`C:\s.cmd`, []string{tc.argument})
		if err != nil {
			t.Fatalf("%q: %v", tc.argument, err)
		}
		want := `cmd.exe /e:ON /v:OFF /d /c ""C:\s.cmd" ` + tc.want + `"`
		if line != want {
			t.Fatalf("%q:\n got %s\nwant %s", tc.argument, line, want)
		}
	}
}

func TestBatchCommandLineRefusesWhatWouldEndTheCommand(t *testing.T) {
	for _, tc := range []struct {
		script    string
		arguments []string
	}{
		{`C:\s.cmd`, []string{"one\ntwo"}},
		{`C:\s.cmd`, []string{"one\rtwo"}},
		{`C:\s.cmd`, []string{"nul\x00"}},
		{`C:\dir\`, nil},
		{`C:\a"b.cmd`, nil},
		{"", nil},
	} {
		if _, err := batchCommandLine(tc.script, tc.arguments); !errors.Is(err, errBatchArgument) {
			t.Fatalf("%q %q: err = %v", tc.script, tc.arguments, err)
		}
	}
}

func TestIsBatchFile(t *testing.T) {
	for name, want := range map[string]bool{
		`C:\m\mvn.cmd`: true, `C:\m\MVN.CMD`: true, `C:\g\gradlew.bat`: true,
		`C:\j\java.exe`: false, `/usr/bin/mvn`: false, `C:\m\mvn.cmd.exe`: false,
	} {
		if got := isBatchFile(name); got != want {
			t.Fatalf("isBatchFile(%q) = %v", name, got)
		}
	}
}
