/** Native workflow inventory; Core owns the schemas and can only narrow them. */
export const ideToolExposure = [
  "lithe_project_inspect", "lithe_environment_inspect", "lithe_environment_configure",
  "lithe_run_list", "lithe_run_start", "lithe_run_restart", "lithe_operations_list",
  "lithe_operation_output", "lithe_operation_stop", "lithe_maven_inspect",
  "lithe_maven_configure", "lithe_maven_reload", "lithe_maven_execute",
].map((name) => ({ name }));
