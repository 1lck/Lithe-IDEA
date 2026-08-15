#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"

for fixture in shared/fixtures/**/*.json; do
    /usr/bin/ruby -rjson -e 'JSON.parse(File.read(ARGV.fetch(0)))' "$fixture"
done

module_fixture="shared/fixtures/modules/built-in-v1.json"
plugin_fixture="shared/fixtures/plugins/official-v1.json"
github_fixture="shared/fixtures/github/pull-request-v1.json"
fixture_ids=$(/usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("modules").map { |m| m.fetch("id") }.sort' "$module_fixture")
swift_ids=$(rg '^[[:space:]]*static let .* = ModuleID\("dev\.lithe\.[^"]+"\)' Sources/LitheModuleAPI/Lifecycle/ModuleTypes.swift \
    | sed -E 's/.*ModuleID\("([^"]+)"\).*/\1/' \
    | sort)
if [[ "$fixture_ids" != "$swift_ids" ]]; then
    print -u2 "Built-in module fixture and Swift ModuleID declarations differ"
    diff <(print -r -- "$fixture_ids") <(print -r -- "$swift_ids") || true
    exit 1
fi

fixture_capability_ids=$(/usr/bin/ruby -rjson -e 'puts JSON.parse(File.read(ARGV.fetch(0))).fetch("modules").flat_map { |m| m.fetch("capabilities") }.uniq.sort' "$module_fixture")
swift_capability_ids=$(rg '^[[:space:]]*static let .* = ModuleCapabilityID\("dev\.lithe\.capability\.[^"]+"\)' Sources/LitheModuleAPI/Lifecycle/ModuleTypes.swift \
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
  abort "capabilities must have one provider" unless modules.flat_map { |m| m.fetch("capabilities") }.uniq.length == modules.length
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

print "Shared contract verification passed: JSON fixtures are valid"
