module github.com/1lck/Lithe-IDEA/desktop

go 1.26.0

// gofmt output differs between releases (1.27 aligns long map keys differently),
// so CI (setup-go reads this line) and local builds must format with one toolchain.
toolchain go1.27.3

require (
	github.com/creack/pty v1.1.24
	github.com/vivaui/viva v0.6.0
	github.com/zalando/go-keyring v0.2.8
	golang.org/x/sys v0.49.0
)

require (
	github.com/danieljoos/wincred v1.2.3 // indirect
	github.com/ebitengine/purego v0.11.1 // indirect
	github.com/godbus/dbus/v5 v5.2.2 // indirect
)

replace github.com/vivaui/viva => github.com/Lithe-IDEA/viva v0.6.1-0.20261112052310-204654f85f56
