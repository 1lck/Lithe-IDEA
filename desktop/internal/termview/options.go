package termview

// Options are the switches of the Terminal settings page (matrix ids terminal-shell-integration
// and terminal-interaction). The zero Options is a terminal's default behavior.
type Options struct {
	// PlainShell starts the user's shell without the integration that reports its prompts,
	// commands and folder (see start). It applies from the next shell the view starts; the one
	// running keeps what it started with.
	PlainShell bool
	// NoClickMove keeps a click on the line being typed from moving the shell's cursor there
	// (see moveInputCursor).
	NoClickMove bool
	// OptionAsMeta sends an Option chord on a Mac keyboard as Escape and the key, the Meta key of
	// shells and Emacs, instead of letting Option type the accent or symbol the layout puts there.
	OptionAsMeta bool
}

// SetOptions changes the switches from the next event or paint on. The workbench calls it every
// frame with the switches its settings name, and once before a view starts its shell.
func (v *View) SetOptions(o Options) {
	v.options = o
}
