package workbench

import "errors"

// This file serves the run tools of the IDE API. A run starts through the Run window's own
// configuration path (startRunConfiguration), so the same saves, launch options and build
// provider apply. The tools never disclose environment values or launch arguments.

// ideAPIRunList lists the saved run configurations with their readiness. Only identity,
// name and whether the run can start now are returned.
func ideAPIRunList(p *project) any {
	configurations := make([]map[string]any, 0, len(p.runConfigs.list))
	for _, configuration := range p.runConfigs.list {
		configurations = append(configurations, map[string]any{
			"configurationID": configuration.ID,
			"name":            configuration.Name,
			"category":        configuration.Category,
			"ready":           p.runConfigurationReady(configuration),
		})
	}
	return map[string]any{"configurations": configurations, "loading": p.runConfigs.loading}
}

// ideAPIRunStart starts a run configuration through the Run window and returns the execution
// it reserved. A refused start reserves nothing and is answered with the refusal's code.
func (a *App) ideAPIRunStart(p *project, configurationID string) (*ideAPIOperation, any) {
	operation, err := a.startRunConfiguration(p, configurationID)
	if err != nil {
		return nil, ideAPIRefusal(err)
	}
	return operation.ide, nil
}

// ideAPIRunRestart starts again the run configuration of one run operation, as a new execution
// with a new ID. A build execution has no configuration to reuse, and an execution that is still
// active must be stopped first, so a restart never runs two executions of the window at once.
func (a *App) ideAPIRunRestart(p *project, operationID string) (*ideAPIOperation, any) {
	operation, failure := p.ideAPIOperationByID(operationID)
	if failure != nil {
		return nil, failure
	}
	if operation.ConfigurationID == "" {
		return nil, ideAPIFailure("NOT_AVAILABLE", "This operation was not started from a run configuration")
	}
	if !operation.terminal() {
		return nil, ideAPIFailure("BUSY", "The operation is still active; stop it first")
	}
	return a.ideAPIRunStart(p, operation.ConfigurationID)
}

// ideAPIRefusal is the failure of a refused start: its own code when the window refused it,
// OPERATION_FAILED for anything else.
func ideAPIRefusal(err error) any {
	var refusal *buildRefusal
	if errors.As(err, &refusal) {
		return ideAPIFailure(refusal.code, refusal.message)
	}
	return ideAPIFailure("OPERATION_FAILED", err.Error())
}
