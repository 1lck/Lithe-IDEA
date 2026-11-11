package core

import "context"

// LaunchCommandRequest is a process launch for Core to fit to the command-line limit
// (execution.planLaunchCommand). Arguments do not include the executable.
// JavaReleaseContents are the release files of the JDK the launcher may belong to, nearest
// first, as the host read them; Core reads the version from the first with JAVA_VERSION.
type LaunchCommandRequest struct {
	Executable          string   `json:"executable"`
	Arguments           []string `json:"arguments"`
	JavaFeatureVersion  *int     `json:"javaFeatureVersion,omitempty"`
	JavaReleaseContents []string `json:"javaReleaseContents,omitempty"`
}

// LaunchArgumentFile is the JDK argument file a planned launch reads: Text in Unicode, and
// the index of the argument the host replaces with "@" and the file's path.
type LaunchArgumentFile struct {
	Text          string `json:"text"`
	ArgumentIndex int    `json:"argumentIndex"`
}

// LaunchCommandPlan is the launch to start: Arguments unchanged and ArgumentFile nil when it
// fits, otherwise the arguments with a placeholder for the argument file.
type LaunchCommandPlan struct {
	Arguments    []string            `json:"arguments"`
	ArgumentFile *LaunchArgumentFile `json:"argumentFile"`
}

// PlanLaunchCommand asks Core whether a launch needs an argument file to fit the command
// line, and what goes into it.
func (c *Client) PlanLaunchCommand(ctx context.Context, request LaunchCommandRequest) (LaunchCommandPlan, error) {
	var plan LaunchCommandPlan
	err := c.Execute(ctx, "execution.planLaunchCommand", request, &plan)
	return plan, err
}
