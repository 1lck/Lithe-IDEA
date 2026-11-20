package core

import "context"

// CLILaunch is Core's interpretation of one bounded CLI invocation.
type CLILaunch struct {
	Action string `json:"action"`
	Path   string `json:"path"`
	Detach bool   `json:"detach"`
}

func (c *Client) PlanCLILaunch(ctx context.Context, args []string) (CLILaunch, error) {
	var result CLILaunch
	err := c.Execute(ctx, "application.cli.planLaunch", struct {
		Args []string `json:"args"`
	}{nonNil(args)}, &result)
	return result, err
}

// CLITarget is the session policy for an observed native path.
type CLITarget struct {
	Mode     string   `json:"mode"`
	Plugins  bool     `json:"plugins"`
	Commands []string `json:"commands"`
}

func (c *Client) CLIOpenTarget(ctx context.Context, kind string) (CLITarget, error) {
	var result CLITarget
	err := c.Execute(ctx, "application.cli.openTarget", struct {
		Kind string `json:"kind"`
	}{kind}, &result)
	return result, err
}

// CLIRegistrationEdit contains the complete owned launcher and source edit.
type CLIRegistrationEdit struct {
	Installed bool   `json:"installed"`
	Owned     bool   `json:"owned"`
	Source    string `json:"source"`
	Launcher  string `json:"launcher"`
}

func (c *Client) EditCLIRegistration(ctx context.Context, shell, source, directory, executable, action, launcherSource string) (CLIRegistrationEdit, error) {
	var result CLIRegistrationEdit
	err := c.Execute(ctx, "application.cli.editRegistration", struct {
		Shell          string `json:"shell"`
		LauncherSource string `json:"launcherSource"`
		Source         string `json:"source"`
		Directory      string `json:"directory"`
		Executable     string `json:"executable"`
		Action         string `json:"action"`
	}{shell, launcherSource, source, directory, executable, action}, &result)
	return result, err
}
