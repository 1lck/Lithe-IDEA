package pluginhost

import (
	"fmt"
	"strings"
)

// Launch kinds the contract defines.
const (
	// LaunchPackaged starts a program shipped inside the package.
	LaunchPackaged = "packaged"
	// LaunchRuntime starts a packaged runtime that loads an entry file.
	LaunchRuntime = "runtime"
	// LaunchSystemCommand starts a bare command the host resolves itself, such as
	// `gopls` or `pylsp`.
	LaunchSystemCommand = "systemCommand"
)

// Launch is the part of a Core launch plan this package verifies: which program
// runs and which package files it needs.
//
// It mirrors only the fields that decide what executes, rather than the whole of
// core.PluginBackendPlan, so the verification stays testable without the kernel.
// The caller that owns the Core client fills it from the plan it received.
type Launch struct {
	// Kind is LaunchPackaged, LaunchRuntime or LaunchSystemCommand.
	Kind string
	// Path is the packaged program, relative to the package.
	Path string
	// Entry is the packaged runtime entry file, relative to the package.
	Entry string
	// PackagedRuntime is the runtime executable, relative to the package.
	PackagedRuntime string
	// Commands are the bare command names a system-command launch offers, in the
	// order the host should try them.
	Commands []string
	// Required are the package-relative paths the launch needs.
	Required []string
}

// Resolved is what VerifyLaunch proved about a launch.
type Resolved struct {
	// Executable is the program that will be started.
	Executable string
	// Entry is the verified entry file, empty when the plan names none.
	Entry string
	// Runtime is the verified runtime executable, empty when the plan names none.
	Runtime string
	// Required holds every verified required path, in plan order.
	Required []string
}

// VerifyLaunch resolves every path a launch will use against the installed
// package.
//
// A launch that names a program it does not ship, or reaches one through a
// symbolic link, is refused here rather than started. Nothing in the plan is
// trusted: the kind decides which fields are required, and every path is resolved
// one segment at a time.
func VerifyLaunch(packageDirectory string, launch Launch) (Resolved, error) {
	switch launch.Kind {
	case LaunchPackaged:
		if launch.Path == "" {
			return Resolved{}, fmt.Errorf("%w: a packaged launch names no program", ErrPackagePath)
		}
		executable, err := ResolveExecutable(packageDirectory, launch.Path)
		if err != nil {
			return Resolved{}, err
		}
		required, err := ResolvePackagePaths(packageDirectory, launch.Required)
		if err != nil {
			return Resolved{}, err
		}
		return Resolved{Executable: executable, Required: required}, nil
	case LaunchRuntime:
		if launch.PackagedRuntime == "" {
			return Resolved{}, fmt.Errorf("%w: a runtime launch names no runtime", ErrPackagePath)
		}
		runtime, err := ResolveExecutable(packageDirectory, launch.PackagedRuntime)
		if err != nil {
			return Resolved{}, err
		}
		resolved := Resolved{Runtime: runtime}
		if launch.Entry != "" {
			entry, err := ResolvePackagePath(packageDirectory, launch.Entry)
			if err != nil {
				return Resolved{}, err
			}
			resolved.Entry = entry
		}
		required, err := ResolvePackagePaths(packageDirectory, launch.Required)
		if err != nil {
			return Resolved{}, err
		}
		resolved.Required = required
		return resolved, nil
	case LaunchSystemCommand:
		// A system-command launch names no package program: the host resolves a bare
		// command itself, so there is nothing here to verify beyond the package files
		// the launch still needs.
		required, err := ResolvePackagePaths(packageDirectory, launch.Required)
		if err != nil {
			return Resolved{}, err
		}
		return Resolved{Required: required}, nil
	default:
		return Resolved{}, fmt.Errorf("%w: unknown launch kind %q", ErrPackagePath, launch.Kind)
	}
}

// ResolveCommand returns the first command the host can find, in the order the
// plan offers them.
//
// A system-command launch names bare commands and the host resolves them with its
// own tool discovery. This client resolves PATH; project toolchains and user
// overrides are not consulted yet, so a plan that depends on them is refused rather
// than started with whatever PATH happens to hold.
//
// A name that carries a separator is refused: the contract lists bare command
// names, and a path would let a plan name a file the host never checked.
func ResolveCommand(commands []string, lookup func(name string) (string, error)) (string, error) {
	if lookup == nil {
		return "", fmt.Errorf("%w: no command lookup", ErrPackagePath)
	}
	for _, command := range commands {
		if command == "" || strings.ContainsAny(command, `/\`) {
			continue
		}
		if path, err := lookup(command); err == nil && path != "" {
			return path, nil
		}
	}
	return "", fmt.Errorf("%w: none of the plan's commands is available", ErrPackagePath)
}

// GrantServices narrows the host services a launch asks for to those this host
// can actually answer.
//
// The contract has the host pass the plan's list through unchanged, so a service
// this host never registered would be advertised and then fail on the first call.
// The intersection is what the start request may carry.
func GrantServices(requested []string, services *Services) []string {
	if services == nil || len(requested) == 0 {
		return nil
	}
	available := make(map[string]struct{})
	for _, method := range services.Grant() {
		available[method] = struct{}{}
	}
	granted := make([]string, 0, len(requested))
	for _, method := range requested {
		if _, ok := available[method]; ok {
			granted = append(granted, method)
		}
	}
	if len(granted) == 0 {
		return nil
	}
	return granted
}
