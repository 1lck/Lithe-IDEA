#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

for fixture in shared/fixtures/**/*.json; do
    /usr/bin/ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$fixture"
done

for schema in shared/contracts/*.schema.json; do
    /usr/bin/ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$schema"
done

module_fixture="shared/fixtures/modules/built-in-v1.json"
plugin_fixture="shared/fixtures/plugins/official-v1.json"
github_fixture="shared/fixtures/github/pull-request-v1.json"
workbench_background_fixture="shared/fixtures/settings/workbench-background-v1.json"
syntax_theme_fixture="shared/fixtures/editor-themes/lithe-v1.json"
maven_platform_fixture="shared/fixtures/maven/platform-contract-v1.json"
maven_portable_schema="shared/contracts/maven-portable-configuration-v1.schema.json"
maven_launch_context_schema="shared/contracts/maven-launch-context-v1.schema.json"
macos_syntax_colors="macos/Sources/Lithe/Resources/SyntaxHighlighting/color-mappings.json"
windows_lithe_theme="windows/tauri/src/extensions/themes/builtin/lithe.json"

/usr/bin/ruby -rjson -e '
  portable = JSON.parse(File.read(ARGV.fetch(0)))
  launch = JSON.parse(File.read(ARGV.fetch(1)))
  fixture = JSON.parse(File.read(ARGV.fetch(2)))

  abort "Maven portable schema ID mismatch" unless portable.fetch("$id").end_with?("/maven-portable-configuration-v1.schema.json")
  portable_fields = %w[customProfiles selectedProfiles skipTests version]
  abort "Maven portable fields differ from v1" unless portable.fetch("properties").keys.sort == portable_fields
  abort "Maven portable required fields differ from v1" unless portable.fetch("required").sort == portable_fields

  abort "Maven launch-context schema ID mismatch" unless launch.fetch("$id").end_with?("/maven-launch-context-v1.schema.json")
  launch_fields = %w[javaHomePath mavenExecutablePath profiles reactorPath settingsPath skipTests version]
  abort "Maven launch-context fields differ from v1" unless launch.fetch("properties").keys.sort == launch_fields.sort
  abort "Maven launch-context required fields differ from v1" unless launch.fetch("required").sort == %w[profiles reactorPath skipTests version]

  abort "Maven platform fixture version must be 1" unless fixture.fetch("version") == 1
  phases = fixture.fetch("lifecyclePhases")
  abort "Maven lifecycle phases differ from v1" unless phases == %w[clean validate compile test package verify install site deploy]
  cases = fixture.fetch("storageIdentityCases")
  abort "Maven storage fixture must cover both platforms" unless cases.map { |item| item.fetch("platform") }.sort == %w[macos windows]
  abort "Maven storage fixture names must be unique" unless cases.map { |item| item.fetch("name") }.uniq.length == cases.length
  abort "Maven storage identities must contain one separator" unless cases.all? { |item| item.fetch("expectedIdentity").count("\0") == 1 }
' "$maven_portable_schema" "$maven_launch_context_schema" "$maven_platform_fixture"

fixture_ids=$(/usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("modules").map { |m| m.fetch("id") }.sort' "$module_fixture")
swift_ids=$(rg '^[[:space:]]*static let .* = ModuleID\("dev\.lithe\.[^"]+"\)' macos/Sources/LitheModuleAPI/Lifecycle/ModuleTypes.swift \
    | sed -E 's/.*ModuleID\("([^"]+)"\).*/\1/' \
    | sort)
if [[ "$fixture_ids" != "$swift_ids" ]]; then
    print -u2 "Built-in module fixture and Swift ModuleID declarations differ"
    diff <(print -r -- "$fixture_ids") <(print -r -- "$swift_ids") || true
    exit 1
fi

fixture_capability_ids=$(/usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("modules").flat_map { |m| m.fetch("capabilities") }.uniq.sort' "$module_fixture")
swift_capability_ids=$(rg '^[[:space:]]*static let .* = ModuleCapabilityID\("dev\.lithe\.capability\.[^"]+"\)' macos/Sources/LitheModuleAPI/Lifecycle/ModuleTypes.swift \
    | sed -E 's/.*ModuleCapabilityID\("([^"]+)"\).*/\1/' \
    | sort)
if [[ "$fixture_capability_ids" != "$swift_capability_ids" ]]; then
    print -u2 "Built-in module fixture and Swift capability declarations differ"
    diff <(print -r -- "$fixture_capability_ids") <(print -r -- "$swift_capability_ids") || true
    exit 1
fi

/usr/bin/ruby -rjson -e '
  data = JSON.parse(File.read(ARGV.fetch(0)))
  abort "module fixture version must be 1" unless data["version"] == 1
  modules = data.fetch("modules")
  abort "module IDs must be sorted" unless modules.map { |m| m.fetch("id") } == modules.map { |m| m.fetch("id") }.sort
  abort "workspace must be the only required module" unless modules.select { |m| m.fetch("required") }.map { |m| m.fetch("id") } == ["dev.lithe.workspace"]
  abort "AI must be disabled by default" unless modules.find { |m| m.fetch("id") == "dev.lithe.ai-assistance" }.fetch("defaultState") == "disabled"
  abort "Database must be disabled by default" unless modules.find { |m| m.fetch("id") == "dev.lithe.database" }.fetch("defaultState") == "disabled"
  allowed_states = ["enabled", "disabled"]
  allowed_scopes = ["application", "workspace"]
  allowed_policies = ["eager", "onDemand", "manual"]
  allowed_sleep_kinds = ["never", "whenIdle"]
  allowed_contribution_kinds = ["command", "toolWindow", "settings", "status"]
  ids = modules.map { |m| m.fetch("id") }
  contribution_ids = []
  modules.each do |m|
    abort "invalid defaultState" unless allowed_states.include?(m.fetch("defaultState"))
    abort "invalid scope" unless allowed_scopes.include?(m.fetch("scope"))
    abort "invalid activationPolicy" unless allowed_policies.include?(m.fetch("activationPolicy"))
    sleep_policy = m.fetch("sleepPolicy")
    abort "invalid sleepPolicy" unless allowed_sleep_kinds.include?(sleep_policy.fetch("kind"))
    if sleep_policy.fetch("kind") == "whenIdle"
      abort "invalid idle interval" unless sleep_policy.fetch("afterSeconds").is_a?(Numeric) && sleep_policy.fetch("afterSeconds") > 0
    else
      abort "never sleep policy must not have an interval" if sleep_policy.key?("afterSeconds")
    end
    dependencies = m.fetch("dependencies")
    abort "dependencies must be sorted" unless dependencies == dependencies.sort
    abort "unknown module dependency" unless dependencies.all? { |dependency| ids.include?(dependency) }
    capabilities = m.fetch("capabilities")
    abort "capabilities must be sorted" unless capabilities == capabilities.sort
    abort "module capability is missing" if capabilities.empty?
    contributions = m.fetch("contributions")
    abort "contributions must be sorted" unless contributions.map { |c| c.fetch("id") } == contributions.map { |c| c.fetch("id") }.sort
    contributions.each do |contribution|
      abort "invalid contribution kind" unless allowed_contribution_kinds.include?(contribution.fetch("kind"))
      contribution_ids << contribution.fetch("id")
    end
  end
  capability_provider_counts = modules
    .flat_map { |m| m.fetch("capabilities") }
    .each_with_object(Hash.new(0)) { |capability, counts| counts[capability] += 1 }
  abort "capabilities must have one provider" unless capability_provider_counts.values.all? { |count| count == 1 }
  abort "contribution IDs must be globally unique" unless contribution_ids.uniq.length == contribution_ids.length
' "$module_fixture"

/usr/bin/ruby -rjson -e '
  plugins = JSON.parse(File.read(ARGV.fetch(0)))
  abort "plugin fixture schema must be 1" unless plugins.fetch("schemaVersion") == 1
  abort "plugin API version must be 1" unless plugins.fetch("pluginAPIVersion") == 1
  entries = plugins.fetch("plugins")
  ids = entries.map { |plugin| plugin.fetch("id") }
  abort "plugin IDs must be sorted" unless ids == ids.sort
  owned_modules = entries.flat_map { |plugin| plugin.fetch("moduleIDs") }
  abort "plugin module IDs must be unique" unless owned_modules.uniq.length == owned_modules.length
  entries.each do |plugin|
    abort "plugin API mismatch" unless plugin.fetch("apiVersion") == plugins.fetch("pluginAPIVersion")
    abort "official plugin signature policy mismatch" unless plugin.fetch("vendor").fetch("signatureRequirement") == "sameTeamAsHost"
    abort "plugin module IDs must be sorted" unless plugin.fetch("moduleIDs") == plugin.fetch("moduleIDs").sort
  end
' "$plugin_fixture"

/usr/bin/ruby -rjson -e '
  data = JSON.parse(File.read(ARGV.fetch(0)))
  abort "GitHub fixture schema must be 1" unless data.fetch("schemaVersion") == 1
  pull = data.fetch("pullRequest")
  labels = pull.fetch("labels").map { |label| label.fetch("name") }
  assignees = pull.fetch("assignees").map { |user| user.fetch("login") }
  abort "GitHub labels must be sorted" unless labels == labels.sort
  abort "GitHub assignees must be sorted" unless assignees == assignees.sort
  abort "GitHub fixture must not contain a credential" if File.read(ARGV.fetch(0)).match?(/accessToken|clientSecret|password/)
' "$github_fixture"

/usr/bin/ruby -rjson -e '
  fixture = JSON.parse(File.read(ARGV.fetch(0)))
  macos = JSON.parse(File.read(ARGV.fetch(1)))
  windows = JSON.parse(File.read(ARGV.fetch(2)))

  abort "syntax theme fixture version must be 1" unless fixture.fetch("version") == 1
  abort "syntax theme fixture ID must be lithe" unless fixture.fetch("id") == "lithe"

  palette_roles = %w[
    attribute boolean comment constant function invalid jsx jsx-attribute keyword null
    number operator property punctuation regex string tag text type variable
  ].sort
  expected_fallbacks = {
    "annotation" => "attribute",
    "documentationComment" => "comment",
    "field" => "property",
    "functionCall" => "function",
    "functionDeclaration" => "function",
    "parameter" => "variable",
    "typeParameter" => "type"
  }
  fallbacks = fixture.fetch("fallbacks")
  abort "syntax role fallbacks differ from v1" unless fallbacks == expected_fallbacks

  appearances = fixture.fetch("appearances")
  abort "syntax theme must define light and dark" unless appearances.keys.sort == %w[dark light]
  color_pattern = /\A#[0-9a-f]{6}(?:[0-9a-f]{2})?\z/i
  appearances.each do |appearance, palette|
    abort "#{appearance} syntax roles differ from v1" unless palette.keys.sort == palette_roles
    palette.each_value do |color|
      abort "invalid #{appearance} syntax color #{color.inspect}" unless color.match?(color_pattern)
    end
  end

  resolve_role = lambda do |appearance, role, trail = []|
    palette = appearances.fetch(appearance)
    return palette.fetch(role) if palette.key?(role)
    abort "unknown syntax role #{role}" unless fallbacks.key?(role)
    abort "cyclic syntax role fallback for #{role}" if trail.include?(role)
    resolve_role.call(appearance, fallbacks.fetch(role), trail + [role])
  end

  macos_role_sources = {
    "text" => "text",
    "keyword" => "keyword",
    "annotation" => "annotation",
    "type" => "type",
    "property" => "property",
    "boolean" => "boolean",
    "constant" => "constant",
    "documentationComment" => "documentationComment",
    "field" => "field",
    "functionCall" => "functionCall",
    "functionDeclaration" => "functionDeclaration",
    "null" => "null",
    "number" => "number",
    "operator" => "operator",
    "parameter" => "parameter",
    "punctuation" => "punctuation",
    "string" => "string",
    "comment" => "comment",
    "typeParameter" => "typeParameter",
    "variable" => "variable"
  }
  macos_defaults = macos.fetch("defaults")
  abort "macOS syntax roles differ from the shared subset" unless macos_defaults.keys.sort == macos_role_sources.keys.sort
  %w[light dark].each do |appearance|
    macos_role_sources.each do |macos_role, shared_role|
      value = macos_defaults.fetch(macos_role)
      abort "macOS #{macos_role} must define light and dark colors" unless value.is_a?(Hash)
      actual = value.fetch(appearance)
      expected = resolve_role.call(appearance, shared_role)
      abort "macOS #{appearance} #{macos_role} differs from shared palette" unless actual.casecmp?(expected)
    end
  end

  windows_syntax_roles = palette_roles - %w[invalid text]
  %w[light dark].each do |appearance|
    theme = windows.fetch("themes").find { |entry| entry.fetch("id") == "lithe-#{appearance}" }
    abort "missing Windows lithe-#{appearance} theme" unless theme
    syntax = theme.fetch("syntax")
    abort "Windows #{appearance} syntax roles differ from v1" unless syntax.keys.sort == windows_syntax_roles
    windows_syntax_roles.each do |role|
      expected = resolve_role.call(appearance, role)
      abort "Windows #{appearance} #{role} differs from shared palette" unless syntax.fetch(role).casecmp?(expected)
    end
    colors = theme.fetch("colors")
    abort "Windows #{appearance} text differs from shared palette" unless colors.fetch("foreground").casecmp?(resolve_role.call(appearance, "text"))
    abort "Windows #{appearance} invalid differs from shared palette" unless colors.fetch("destructive").casecmp?(resolve_role.call(appearance, "invalid"))
  end
' "$syntax_theme_fixture" "$macos_syntax_colors" "$windows_lithe_theme"

/usr/bin/ruby -rjson -e '
  background = JSON.parse(File.read(ARGV.fetch(0)))
  abort "workbench background fixture version must be 1" unless background.fetch("version") == 1
  abort "workbench background fixture has unexpected fields" unless background.keys.sort == ["opacity", "source", "version"]
  opacity = background.fetch("opacity")
  abort "workbench background opacity must be between 0.05 and 1" unless opacity.is_a?(Numeric) && opacity.between?(0.05, 1)
  source = background.fetch("source")
  kind = source.fetch("kind")
  abort "invalid workbench background source" unless ["none", "bundled", "custom"].include?(kind)
  if kind == "bundled"
    abort "bundled workbench background requires a stable slot" unless source.keys.sort == ["bundledSlot", "kind"] && source.fetch("bundledSlot").match?(/^(0[1-9]|10)$/)
  else
    abort "non-bundled workbench background must not carry platform data" unless source.keys == ["kind"]
  end
' "$workbench_background_fixture"

print "Shared contract verification passed: JSON fixtures are valid"
