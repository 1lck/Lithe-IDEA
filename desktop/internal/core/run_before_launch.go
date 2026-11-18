package core

import "context"

// RunBeforeLaunch is what `runConfig.beforeLaunch` answers: Status "ok" with the
// steps to run in order and, when a project file names them, the Confirmation to
// ask for; or "rejected" with the Refusal of the step that cannot run.
type RunBeforeLaunch struct {
	Status       string                       `json:"status"`
	Steps        []RunBeforeLaunchItem        `json:"steps"`
	Confirmation *RunBeforeLaunchConfirmation `json:"confirmation"`
	Refusal      *RunBeforeLaunchRefusal      `json:"refusal"`
}

// RunBeforeLaunchItem is one run to start before the configuration: its ID, its
// name and a line naming what it starts, shown in the confirmation.
type RunBeforeLaunchItem struct {
	ConfigurationID string `json:"configurationId"`
	Name            string `json:"name"`
	Summary         string `json:"summary"`
}

// RunBeforeLaunchConfirmation identifies a list of steps a project file names; the
// host asks once per Fingerprint before running it.
type RunBeforeLaunchConfirmation struct {
	Fingerprint string `json:"fingerprint"`
}

// RunBeforeLaunchRefusal is why the steps cannot run: Code is notFound,
// notAllowed, unavailable, cycle or tooLong, about step ConfigurationID.
type RunBeforeLaunchRefusal struct {
	Code            string `json:"code"`
	ConfigurationID string `json:"configurationId"`
}

// RunBeforeLaunch expands the built-in process runs configurationID starts first.
func (c *Client) RunBeforeLaunch(ctx context.Context, root, configurationID string) (RunBeforeLaunch, error) {
	var result RunBeforeLaunch
	err := c.Execute(ctx, "runConfig.beforeLaunch", struct {
		Root            string `json:"root"`
		ConfigurationID string `json:"configurationId"`
	}{root, configurationID}, &result)
	return result, err
}
