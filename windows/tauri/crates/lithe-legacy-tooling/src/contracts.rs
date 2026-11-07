//! Response models for the legacy Java commands.
//!
//! These are copies of the types in lithe-core's `protocol/contracts.rs`. Core
//! keeps them private to its crate, and the JSON they produce must stay
//! identical to what Core returns today so the Windows TypeScript needs no
//! change.

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Maven profile identity and its default activation state.
pub struct MavenProfileResponse {
    pub id: String,
    pub is_active_by_default: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One module in the declared Maven reactor hierarchy.
pub struct MavenModuleResponse {
    pub relative_path: String,
    pub group_id: Option<String>,
    pub artifact_id: String,
    pub version: Option<String>,
    pub packaging: String,
    pub source_roots: Vec<MavenSourceRootResponse>,
    pub modules: Vec<MavenModuleResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One Maven source root relative to its owning module.
pub struct MavenSourceRootResponse {
    /// Module-relative path using `/` separators.
    pub path: String,
    /// Semantic source-set used by project and Java tooling views.
    pub kind: MavenSourceRootKind,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
/// Maven source-root categories kept distinct for main, test, and generated code.
pub enum MavenSourceRootKind {
    /// Production Java sources.
    MainJava,
    /// Production resource files.
    MainResources,
    /// Test Java sources.
    TestJava,
    /// Test resource files.
    TestResources,
    /// Generated production sources.
    GeneratedMain,
    /// Generated test sources.
    GeneratedTest,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Maven reactor identity, modules, profiles, and wrapper availability.
pub struct MavenScanResponse {
    pub relative_path: String,
    pub group_id: Option<String>,
    pub artifact_id: String,
    pub version: Option<String>,
    pub packaging: String,
    pub source_roots: Vec<MavenSourceRootResponse>,
    pub modules: Vec<MavenModuleResponse>,
    pub profiles: Vec<MavenProfileResponse>,
    pub has_wrapper: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Platform-neutral executable reference returned by Maven launch planning.
pub struct MavenLaunchExecutableResponse {
    pub toolchain: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Deterministic Maven invocation consumed by native process adapters.
pub struct MavenLaunchPlanResponse {
    pub version: u32,
    pub executable: MavenLaunchExecutableResponse,
    pub arguments: Vec<String>,
    pub working_directory: String,
    pub configuration_fingerprint: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Resolution outcome reported by Maven for one dependency coordinate.
pub enum MavenDependencyResolutionResponse {
    /// Maven selected this dependency in the effective tree.
    Resolved,
    /// Maven omitted this occurrence because the same dependency was already selected.
    OmittedDuplicate,
    /// Maven omitted this occurrence in favor of another version.
    OmittedConflict,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One bounded Maven dependency node with recursively nested transitive children.
pub struct MavenDependencyResponse {
    /// Reactor-relative module whose POM produced this dependency tree.
    pub module_path: String,
    pub group_id: String,
    pub artifact_id: String,
    pub version: String,
    /// Maven artifact type such as `jar`, `war`, or `test-jar`.
    pub r#type: String,
    /// Optional Maven classifier such as `tests`.
    pub classifier: Option<String>,
    pub scope: String,
    pub resolution: MavenDependencyResolutionResponse,
    /// Version Maven selected when this occurrence was omitted for conflict.
    pub selected_version: Option<String>,
    /// Version before dependency management replaced it with `version`.
    pub premanaged_version: Option<String>,
    /// Scope before dependency management replaced it with `scope`.
    pub premanaged_scope: Option<String>,
    /// Declared scope before mediation widened it to `scope`.
    pub original_scope: Option<String>,
    /// Wider scope from another path that mediation did not apply here.
    pub ignored_scope: Option<String>,
    pub children: Vec<MavenDependencyResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Deterministically ordered dependency tree for one Maven reactor module.
pub struct MavenDependenciesResponse {
    /// Reactor-relative module path, using `.` for the reactor root.
    pub module_path: String,
    pub dependencies: Vec<MavenDependencyResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One normalized issue parsed from Maven process output.
pub struct MavenDiagnosticResponse {
    pub path: String,
    pub line: usize,
    pub column: Option<usize>,
    pub severity: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Maven diagnostics in stable source order.
pub struct MavenDiagnosticsResponse {
    pub issues: Vec<MavenDiagnosticResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One failed or errored JUnit test reported by Maven Surefire/Failsafe.
pub struct MavenTestFailureResponse {
    /// Provider-reported test name, usually `method(Class)` or `Class.method`.
    pub name: String,
    /// Either `failure` or `error`, matching the Surefire result section.
    pub kind: String,
    /// Short assertion or exception message when Maven printed one.
    pub message: Option<String>,
    /// Workspace-relative source path when a stack frame resolves to a file.
    pub path: Option<String>,
    /// One-based source line from the first matching stack frame.
    pub line: Option<usize>,
    /// UTF-16 column is not emitted by Surefire's text reporter.
    pub column: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Bounded, deterministic JUnit result summary parsed from Maven output.
pub struct MavenTestResultsResponse {
    /// Total tests from the final Results summary or aggregated class summaries.
    pub tests_run: usize,
    /// Tests that failed an assertion.
    pub failures: usize,
    /// Tests that terminated with an error or exception.
    pub errors: usize,
    /// Tests skipped by assumptions, tags, or configuration.
    pub skipped: usize,
    /// Derived number of tests that completed successfully.
    pub passed: usize,
    /// True when the parsed summary contains no failures or errors.
    pub success: bool,
    /// Individual failures and errors in the order Maven reported them.
    pub failure_details: Vec<MavenTestFailureResponse>,
    /// Per-method outcomes read from the run's XML reports, ordered by class
    /// and method. Empty when the request did not ask for reports or the run
    /// wrote none.
    pub test_cases: Vec<MavenTestCaseResponse>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
/// Aggregated outcome of one test method in a Maven test run.
pub struct MavenTestCaseResponse {
    /// Binary class name from the report, such as `demo.OrderTest$Refunds`.
    pub class_name: String,
    /// Java method name without parameters or invocation index.
    pub method: String,
    /// `passed`, `failed`, `error`, or `skipped`. With several invocations
    /// (parameterized or repeated tests) the most severe one wins.
    pub status: String,
    /// First assertion or exception message of the failing invocation.
    pub message: Option<String>,
    /// Number of `<testcase>` entries aggregated into this method.
    pub invocations: usize,
    /// Sum of reported invocation times in milliseconds; absent if any time is missing or invalid.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_millis: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Zero-based UTF-16 location of a Java declaration.
pub struct JavaSourceDefinitionResponse {
    pub line: usize,
    pub utf16_column: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One Spring configuration property and its optional Java declaration.
pub struct SpringPropertyResponse {
    pub name: String,
    pub type_name: Option<String>,
    pub description: Option<String>,
    pub default_value: Option<String>,
    pub source_path: Option<String>,
    pub source_line: Option<usize>,
    pub source_column: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One key/value occurrence from a Spring application configuration document.
pub struct SpringConfigurationValueResponse {
    pub key: String,
    pub value: String,
    pub path: String,
    pub line: usize,
    pub column: usize,
    pub profile: Option<String>,
    pub overrides_base_value: bool,
    pub target_path: Option<String>,
    pub target_line: Option<usize>,
    pub target_column: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Java `@Value` reference to a Spring configuration property.
pub struct SpringPropertyReferenceResponse {
    pub key: String,
    pub path: String,
    pub line: usize,
    pub column: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Spring configuration problem projected onto one source location.
pub struct SpringDiagnosticResponse {
    pub path: String,
    pub line: usize,
    pub column: usize,
    pub severity: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Component or `@Bean` declaration available for dependency injection.
pub struct SpringBeanResponse {
    pub id: String,
    pub name: String,
    pub type_name: String,
    pub path: String,
    pub line: usize,
    pub column: usize,
    pub kind: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Injection point and the bean declarations that satisfy it.
pub struct SpringInjectionResponse {
    pub path: String,
    pub line: usize,
    pub column: usize,
    pub type_name: String,
    pub qualifier: Option<String>,
    pub bean_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// HTTP endpoint declared by a Spring MVC controller method.
pub struct SpringEndpointResponse {
    pub id: String,
    pub http_methods: Vec<String>,
    pub route: String,
    pub controller: String,
    pub method: String,
    pub path: String,
    pub line: usize,
    pub column: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Complete deterministic Spring semantic index for one workspace snapshot.
pub struct SpringIndexResponse {
    pub properties: Vec<SpringPropertyResponse>,
    pub values: Vec<SpringConfigurationValueResponse>,
    pub property_references: Vec<SpringPropertyReferenceResponse>,
    pub diagnostics: Vec<SpringDiagnosticResponse>,
    pub beans: Vec<SpringBeanResponse>,
    pub injections: Vec<SpringInjectionResponse>,
    pub endpoints: Vec<SpringEndpointResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One MyBatis statement that has both a Java mapper method and an XML `id`.
pub struct MybatisStatementResponse {
    /// Stable identity: namespace, statement id, XML path, and XML line.
    pub id: String,
    /// Fully qualified mapper type from the XML `namespace`.
    pub namespace: String,
    /// XML statement `id`, which matches the Java method name.
    pub statement_id: String,
    /// MyBatis statement kind: `select`, `insert`, `update`, or `delete`.
    pub kind: String,
    /// Workspace-relative Java mapper path.
    pub java_path: String,
    /// One-based line of the Java method name.
    pub java_line: usize,
    /// One-based UTF-16 column of the Java method name.
    pub java_column: usize,
    /// One-based line of the Java method signature terminator.
    pub java_end_line: usize,
    /// Exclusive one-based UTF-16 column after the Java method name.
    pub java_end_column: usize,
    /// Workspace-relative mapper XML path.
    pub xml_path: String,
    /// One-based line of the XML statement `id` value.
    pub xml_line: usize,
    /// One-based UTF-16 column of the XML statement `id` value.
    pub xml_column: usize,
    /// Exclusive one-based UTF-16 column after the XML statement `id` value.
    pub xml_end_column: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Complete deterministic MyBatis mapper/XML index for one workspace snapshot.
pub struct MybatisIndexResponse {
    /// Paired Java methods and XML statements, ordered by namespace and id.
    pub statements: Vec<MybatisStatementResponse>,
}
