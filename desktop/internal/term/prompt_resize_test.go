package term

import (
	"strings"
	"testing"
)

// shellStarted is the OSC 133 C the Bash and Zsh integration writes once as the
// shell starts, which tells the terminal that this shell marks its commands.
const shellStarted = "\x1b]133;C;motty=t\x07"

// A shell's line editor redraws its prompt after a resize from the rows it last
// drew it on: it clears the current row, moves up as many rows as it had drawn,
// and writes the prompt again. Reflowing those rows underneath it moves the text
// the redraw is based on, and the prompt is left on screen a second time.
func TestResizeLeavesTheShellPromptForTheShellToRedraw(t *testing.T) {
	prompt := "Tdaofei@user-System-Product-Name:/data/Tdaofei/project/DefMamba-main$ (base) "
	visible := strings.TrimRight(prompt, " ") // the retained text drops trailing blanks
	promptMarker := "\x1b]133;A;motty=t\x07"
	for _, test := range []struct {
		name   string
		cols   int
		resize int
		redraw string
	}{
		// Bash 5.2 at 118 columns, prompt printed on one row, then narrowed:
		// it has not seen the prompt wrap and redraws it from the current row.
		{"redrawn as one row", 118, 65,
			"\r\x1b[K\r" + prompt[:66] + "\r" + prompt[65:]},
		// The prompt was already wrapped at 65, so the redraw moves up one row
		// before writing the prompt at 55 columns.
		{"redrawn after wrapping", 65, 55,
			"\r\x1b[K\r\x1b[A\x1b[K\r" + prompt[:58] + "\r" + prompt[55:]},
	} {
		t.Run(test.name, func(t *testing.T) {
			terminal := New(test.cols, 12, 100)
			terminal.SetPromptToken("t")
			feed(terminal, shellStarted+promptMarker+prompt)
			terminal.Resize(test.resize, 12)
			feed(terminal, test.redraw)
			text := strings.TrimRight(string(terminal.AppendRetainedText(nil)), " ")
			if text != visible {
				t.Fatalf("the redraw left %q instead of the one prompt %q", text, visible)
			}
		})
	}
}

// A prompt leaves its layout to the shell, but the output a command writes after
// it is the terminal's to reflow: OSC 133 C ends the prompt and the output a
// command writes is wrapped again at the new width.
func TestResizeReflowsOutputAfterThePromptEnds(t *testing.T) {
	terminal := New(40, 8, 100)
	terminal.SetPromptToken("t")
	feed(terminal, shellStarted+"\x1b]133;A;motty=t\x07$ \x1b]133;C;motty=t\x07")
	line := "output that is longer than the terminal is wide"
	feed(terminal, line)
	terminal.Resize(20, 8)
	if text := string(terminal.AppendRetainedText(nil)); !strings.Contains(text, line) {
		t.Fatalf("the output was not reflowed at the new width:\n%s", text)
	}
}

// A resize at a prompt leaves the prompt and the input the shell has not
// redrawn yet on screen, cut only by the new width: readers such as the command
// recorder and completion see the line until the shell replaces it.
func TestResizeKeepsThePromptOnScreenUntilTheShellRedraws(t *testing.T) {
	prompt := "Tdaofei@user-System-Product-Name:/data/Tdaofei/project/DefMamba-main$ (base) "
	terminal := New(118, 12, 100)
	terminal.SetPromptToken("t")
	feed(terminal, shellStarted+"\x1b]133;A;motty=t\x07"+prompt)
	terminal.Resize(65, 12)
	text := string(terminal.AppendRetainedText(nil))
	if len(text) < 32 || !strings.HasPrefix(prompt, text) {
		t.Fatalf("the prompt is %q right after the resize, want its visible %q", text, prompt[:32])
	}
}

// Narrowing and widening again before the shell redraws leaves the prompt and
// the cursor where the shell believes they are: the rows are kept aside and put
// back, so nothing under the new width is lost.
func TestResizeBackToItsWidthRestoresThePrompt(t *testing.T) {
	prompt := "Tdaofei@user-System-Product-Name:/data/Tdaofei/project/DefMamba-main$ (base) "
	terminal := New(118, 12, 100)
	terminal.SetPromptToken("t")
	feed(terminal, shellStarted+"\x1b]133;A;motty=t\x07"+prompt)
	terminal.Resize(60, 12)
	terminal.Resize(118, 12)
	text := string(terminal.AppendRetainedText(nil))
	if text != strings.TrimRight(prompt, " ") {
		t.Fatalf("the prompt came back as %q", text)
	}
	if terminal.cx != len(prompt) {
		t.Fatalf("the cursor is at column %d, want it after the prompt at %d", terminal.cx, len(prompt))
	}
}

// A shell that marks its prompts but never the start of a command (the
// PowerShell and cmd.exe prompts on Windows) gives no sign of where the prompt
// ends and a command's output begins. Its prompt is not kept aside, so a resize
// while the command runs reflows the output instead of clearing it as a stale
// prompt when the command next prints.
func TestResizeKeepsOutputOfAShellThatDoesNotMarkCommands(t *testing.T) {
	terminal := New(40, 8, 100)
	terminal.SetPromptToken("t")
	feed(terminal, "\x1b]133;A;motty=t\x07PS> \x1b]133;B;motty=t\x07")
	line := "output that is longer than the terminal is wide"
	feed(terminal, line)
	if terminal.AtPrompt() {
		t.Fatal("a shell that never marked a command is taken to be at its prompt")
	}
	terminal.Resize(20, 8)
	feed(terminal, " more")
	text := strings.ReplaceAll(string(terminal.AppendRetainedText(nil)), "\n", "")
	if !strings.Contains(text, "PS> "+line+" more") {
		t.Fatalf("the command's output was lost across the resize:\n%s", text)
	}
}

// A new token is a new shell, which has not yet said that it marks commands.
func TestNewPromptTokenForgetsCommandMarks(t *testing.T) {
	terminal := New(40, 8, 100)
	terminal.SetPromptToken("t")
	feed(terminal, shellStarted+"\x1b]133;A;motty=t\x07$ ")
	if !terminal.CommandReporting() || !terminal.AtPrompt() {
		t.Fatal("the owning shell's marks were not taken")
	}
	terminal.SetPromptToken("u")
	if terminal.CommandReporting() || terminal.AtPrompt() {
		t.Fatal("the old shell's marks survived a new token")
	}
	feed(terminal, shellStarted)
	if terminal.CommandReporting() {
		t.Fatal("a command mark under the old token was taken for the new shell's")
	}
}
