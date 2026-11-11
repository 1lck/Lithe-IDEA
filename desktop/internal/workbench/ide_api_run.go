package workbench

import "fmt"

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

// ideAPIRunStart records a run as an IDE operation and starts it. The operation is recorded
// before the start so the answer carries its ID; a start refused before it began is removed
// again, and a save failure after the record settles it as failed.
func (a *App) ideAPIRunStart(p *project, configurationID string) any {
	configuration := p.runConfigs.configuration(configurationID)
	if configuration == nil {
		return ideAPIFailure("INVALID_ARGUMENTS", "Unknown run configuration")
	}
	if p.build.operation != nil {
		return ideAPIFailure("OPERATION_BUSY", "The Build window is already running an operation")
	}
	p.ideAPI.nextOperation++
	operation := &ideAPIOperation{
		ID:              fmt.Sprintf("ide-run-%d", p.ideAPI.nextOperation),
		Label:           configuration.Name,
		State:           "running",
		startSequence:   p.build.outputSequence,
		ConfigurationID: configurationID,
	}
	p.ideAPI.operations = append(p.ideAPI.operations, operation)
	if err := a.startRunConfiguration(p, configurationID, func() { operation.State = "failed" }); err != nil {
		p.ideAPI.operations = p.ideAPI.operations[:len(p.ideAPI.operations)-1]
		return ideAPIFailure("INVALID_ARGUMENTS", err.Error())
	}
	return map[string]any{"operationID": operation.ID, "state": operation.State}
}

// ideAPIRunRestart starts again the run configuration of one recorded run operation. A
// build execution has no configuration to reuse and is refused.
func (a *App) ideAPIRunRestart(p *project, operationID string) any {
	operation := p.ideAPI.operation(operationID)
	if operation == nil {
		return ideAPIFailure("INVALID_ARGUMENTS", "Unknown operation")
	}
	if operation.ConfigurationID == "" {
		return ideAPIFailure("NOT_AVAILABLE", "This operation was not started from a run configuration")
	}
	return a.ideAPIRunStart(p, operation.ConfigurationID)
}
