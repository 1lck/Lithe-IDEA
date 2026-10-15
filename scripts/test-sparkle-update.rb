#!/usr/bin/env ruby
require "tmpdir"
require "fileutils"
require "open3"
require "timeout"
require "time"
require "digest"
require "base64"
require "json"
require_relative "select-sparkle-baselines"
require_relative "verify-sparkle-appcast"

# Integration test: uses the pinned Sparkle tools and local macOS signing tools.
# No network, Keychain access, installed application, or production key is used.
def run(*command, input: "", succeeds: true)
  output = ""
  result = nil
  environment = {"CFFIXED_USER_HOME" => @fixture_home}
  Open3.popen2e(environment, *command, pgroup: true) do |stdin, stream, process|
    begin
      Timeout.timeout(60) do
        stdin.write(input)
        stdin.close
        output = stream.read
        result = process.value
      end
    ensure
      unless result
        Process.kill("KILL", -process.pid) rescue Errno::ESRCH
        process.join(5)
      end
    end
  end
  raise "Unexpected result for #{command.first}: #{output}" unless result.success? == succeeds
  output
end

def expect(condition, message)
  raise message unless condition
end

# Optional report records each integration scenario separately, including failures.
$timing_cases = []
def timed_test(name)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  status = "failed"
  yield
  status = "passed"
ensure
  $timing_cases << {name: name, suite: "Sparkle integration", status: status,
    durationMs: (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000, maxMs: 120_000,
    details: status == "failed" ? $!&.message.to_s : ""}
  if ENV["LITHE_TEST_REPORT_PATH"]
    File.write(ENV.fetch("LITHE_TEST_REPORT_PATH"), JSON.pretty_generate({runner: "release-infrastructure", warnMs: 1000, tests: $timing_cases}))
  end
end

tools = ARGV.fetch(0)
timed_test("rollback DMG signature compatibility") do
Dir.mktmpdir("lithe-rollback-signatures-") do |root|
  @fixture_home = File.join(root, "home")
  FileUtils.mkdir_p(@fixture_home)
  key = Base64.strict_encode64("\x01" * 32)
  %w[arm64 x86_64].each do |architecture|
    path = File.join(root, "Lithe-1.0.0-#{architecture}.dmg")
    File.write(path, "full archive #{architecture}")
    File.write(path + ".sha256", Digest::SHA256.file(path).hexdigest)
    signature = run(File.join(tools, "sign_update"), "--ed-key-file", "-", "-p", path, input: key + "\n").strip
    File.write(path + ".edsig", signature + "\n")
    run("swift", "-e", 'import CryptoKit; import Foundation; let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)); let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])); guard key.publicKey.isValidSignature(Data(base64Encoded: CommandLine.arguments[2])!, for: data) else { exit(1) }', path, signature)
  end
  generator = ["ruby", File.join(__dir__, "create-macos-update-manifest.rb"), "--version", "1.0.0",
               "--repository", "example/lithe", "--output-directory", root, "--require-signatures"]
  run(*generator)
  manifest = JSON.parse(File.read(File.join(root, "latest-macos.json")))
  %w[arm64 x86_64].each do |architecture|
    expect(manifest.fetch("assets").fetch(architecture).fetch("edSignature") == File.read(File.join(root, "Lithe-1.0.0-#{architecture}.dmg.edsig")).strip,
      "Manifest must preserve the Sparkle-compatible archive signature")
  end
  File.delete(File.join(root, "Lithe-1.0.0-arm64.dmg.edsig"))
  run(*generator, succeeds: false)
  File.write(File.join(root, "Lithe-1.0.0-arm64.dmg.edsig"), "invalid")
  run(*generator, succeeds: false)
end
puts "Rollback DMG signatures, CryptoKit compatibility and required manifest fields passed"
end
[false, true].each do |preview|
timed_test(preview ? "AutoBuild timestamp and legacy delta" : "stable signed full update and delta") do
Dir.mktmpdir("lithe-sparkle-test-") do |root|
  @fixture_home = File.join(root, "home")
  FileUtils.mkdir_p(@fixture_home)
  key = Base64.strict_encode64("\x01" * 32)
  public_key = run("swift", "-e", 'import CryptoKit; import Foundation; print(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)).publicKey.rawRepresentation.base64EncodedString())').strip
  archives = File.join(root, "archives")
  FileUtils.mkdir_p(archives)
  originals = []
  pinned_timestamp = "2026-01-02T03:04:05Z"
  [1, 2].each do |version|
    build = preview ? (version == 1 ? "58.1" : "20260102.030405") : version.to_s
    app = File.join(root, "v#{version}", "Lithe.app")
    originals << app
    FileUtils.mkdir_p(File.join(app, "Contents", "MacOS"))
    FileUtils.mkdir_p(File.join(app, "Contents", "Resources"))
    FileUtils.cp("/usr/bin/true", File.join(app, "Contents", "MacOS", "Lithe"))
    plist = {"CFBundleIdentifier" => "example.lithe.sparkle-fixture", "CFBundleName" => "Lithe",
      "CFBundleExecutable" => "Lithe", "CFBundlePackageType" => "APPL",
      "CFBundleVersion" => build, "CFBundleShortVersionString" => preview ? "0.3.0" : "1.0.#{version}",
      "LSMinimumSystemVersion" => "13.0", "SUPublicEDKey" => public_key,
      "SUFeedURL" => "https://example.com/appcast.xml"}
    plist["LitheBuildTimestamp"] = pinned_timestamp if preview
    document = REXML::Document.new('<plist version="1.0"><dict/></plist>')
    plist.each do |name, value|
      document.root.elements["dict"].add_element("key").text = name
      document.root.elements["dict"].add_element("string").text = value
    end
    File.write(File.join(app, "Contents", "Info.plist"), document.to_s)
    File.binwrite(File.join(app, "Contents", "Resources", "unchanged"), Random.new(529).bytes(512 * 1024))
    File.write(File.join(app, "Contents", "Resources", "changed"), version.to_s)
    run("codesign", "--force", "--deep", "--sign", "-", app)
    run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, File.join(archives, "Lithe-#{version}.zip"))
    if version == 1
      run(File.join(tools, "generate_appcast"), "--ed-key-file", "-", "--versions", build, "--download-url-prefix", "https://example.com/", archives, input: key + "\n")
      verify_sparkle_appcast(File.join(archives, "appcast.xml"), build)
      expect(Dir.glob(File.join(archives, "*.delta")).empty?, "Bootstrap release must use a full update")
    end
  end
  feed = File.join(archives, "appcast.xml")
  target_build = preview ? "20260102.030405" : "2"
  notes = "# Changes\n\nOpening files is faster. A & B < C.\n"
  File.write(File.join(archives, "Lithe-2.txt"), notes) unless preview
  File.delete(feed) # Release jobs reconstruct the feed from archived ZIPs.
  run(File.join(tools, "generate_appcast"), "--embed-release-notes", "--ed-key-file", "-", "--versions", target_build, "--maximum-versions", "1", "--download-url-prefix", "https://example.com/", archives, input: key + "\n")
  verify_sparkle_appcast(feed, target_build)
  run("ruby", File.join(__dir__, "name-sparkle-deltas.rb"), feed, "arm64")
  if preview
    bundle_timestamp = run("/usr/libexec/PlistBuddy", "-c", "Print :LitheBuildTimestamp",
      File.join(originals.last, "Contents", "Info.plist")).strip
    %w[arm64 x86_64].each do |architecture|
      architecture_feed = File.join(root, "appcast-#{architecture}.xml")
      FileUtils.cp(feed, architecture_feed)
      run("ruby", File.join(__dir__, "set-preview-appcast-date.rb"), architecture_feed, pinned_timestamp, target_build)
      date = REXML::Document.new(File.read(architecture_feed)).root.elements["channel/item/pubDate"].text
      expect(Time.rfc2822(date).utc.iso8601 == bundle_timestamp, "Both architectures must use the app's pinned build timestamp")
      verify_autobuild_feed(architecture_feed, target_build, pinned_timestamp)
      title = REXML::Document.new(File.read(architecture_feed)).root.elements["channel/item/title"].text
      expect(title == "AutoBuild — 构建自 2026-01-02 03:04:05 UTC", "Update title must show the shared UTC build time")
    end
    run("ruby", File.join(__dir__, "set-preview-appcast-date.rb"), feed, pinned_timestamp, target_build)
  end
  run(File.join(tools, "sign_update"), "--ed-key-file", "-", feed, input: key + "\n")
  run(File.join(tools, "sign_update"), "--verify", "--ed-key-file", "-", feed, input: key + "\n")
  verify_sparkle_appcast(feed, target_build)
  delta = Dir.glob(File.join(archives, "*.delta")).first
  expect(delta, "Expected a usable delta for consecutive versions")
  expect(delta.end_with?("-arm64.delta"), "Delta asset names must include architecture")
  patched = File.join(root, "patched.app")
  run(File.join(tools, "BinaryDelta"), "apply", originals.first, patched, delta)
  run("diff", "-rq", originals.last, patched)
  run("codesign", "--verify", "--deep", "--strict", patched)
  item = REXML::Document.new(File.read(feed)).root.elements["channel/item"]
  description = item.elements["description"]&.text
  expect(preview ? description.nil? : description == notes, "Stable notes must survive feed signing as plain text; previews must omit them")
  enclosure = item.elements["sparkle:deltas/enclosure"]
  signature = enclosure.attributes["sparkle:edSignature"]
  run(File.join(tools, "sign_update"), "--verify", "--ed-key-file", "-", delta, signature, input: key + "\n")
  File.open(delta, "ab") { |file| file.write("corrupt") }
  run(File.join(tools, "sign_update"), "--verify", "--ed-key-file", "-", delta, signature, input: key + "\n", succeeds: false)
  expect(item.elements["enclosure"], "Full update must remain available with a delta")
  puts "Bootstrap, delta application, signature rejection, and full fallback metadata passed"
end
end

end

timed_test("channel feed and preference isolation") do
Dir.mktmpdir("lithe-sparkle-channels-") do |root|
  @fixture_home = File.join(root, "home")
  FileUtils.mkdir_p(@fixture_home)
  key = Base64.strict_encode64("\x01" * 32)
  %w[stable autobuild preview].product(%w[arm64 x86_64]).each do |channel, architecture|
    path = File.join(root, "#{channel}-#{architecture}.plist")
    File.write(path, '<plist version="1.0"><dict/></plist>')
    run("env", "LITHE_UPDATE_CHANNEL=#{channel}", "LITHE_PREVIEW_TAG=ignored-legacy-tag",
      "LITHE_SPARKLE_PUBLIC_KEY=#{key}", "GITHUB_REPOSITORY=example/lithe",
      "zsh", File.join(__dir__, "configure-sparkle-app.sh"), path, architecture)
    info = JSON.parse(run("plutil", "-convert", "json", "-o", "-", path))
    normalized = channel == "preview" ? "autobuild" : channel
    stable_feed = "https://github.com/example/lithe/releases/latest/download/appcast-#{architecture}.xml"
    autobuild_feed = "https://github.com/example/lithe/releases/download/AutoBuild/appcast-preview-#{architecture}.xml"
    expected = normalized == "autobuild" ? autobuild_feed : stable_feed
    expect(info["SUFeedURL"] == expected, "Update channels must use separate architecture-specific feeds")
    expect(info["LitheUpdateChannel"] == normalized, "Legacy preview must identify as AutoBuild")
    expect(info["SUDefaultsDomain"] == "app.lithe.desktop.sparkle.#{normalized}", "Sparkle preferences must be isolated per channel")
    expect(info["LitheStableFeedURL"] == stable_feed, "Stable selection must never reuse an installed AutoBuild feed")
    expect(info["LitheAutoBuildFeedURL"] == autobuild_feed, "AutoBuild must use its fixed tag despite legacy overrides")
    expect(info["LitheStableReleaseURL"] == "https://github.com/example/lithe/releases/latest", "Stable full installer must use the stable page")
    expect(info["LitheAutoBuildReleaseURL"] == "https://github.com/example/lithe/releases/tag/AutoBuild", "AutoBuild full installer must use its fixed tag")
    expect(info["SUPublicEDKey"] == key, "Both channels must validate signed updates")
  end
  # Use isolated test suites derived from the actual packaged domains. Never
  # write the developer's live Sparkle preferences while testing channel changes.
  stable = JSON.parse(run("plutil", "-convert", "json", "-o", "-", File.join(root, "stable-arm64.plist"))).fetch("SUDefaultsDomain")
  preview = JSON.parse(run("plutil", "-convert", "json", "-o", "-", File.join(root, "preview-arm64.plist"))).fetch("SUDefaultsDomain")
  run("swift", "-e", <<~'SWIFT', stable, preview)
    import Foundation
    let suffix = ".fixture." + UUID().uuidString
    let stableName = CommandLine.arguments[1] + suffix
    let previewName = CommandLine.arguments[2] + suffix
    let stable = UserDefaults(suiteName: stableName)!
    let preview = UserDefaults(suiteName: previewName)!
    defer {
        stable.removePersistentDomain(forName: stableName)
        preview.removePersistentDomain(forName: previewName)
    }
    let skippedKey = "SUSkippedMinorVersion"
    preview.set("201.1", forKey: skippedKey)
    guard stable.string(forKey: skippedKey) == nil else { exit(1) }
    stable.set("51", forKey: skippedKey)
    guard preview.string(forKey: skippedKey) == "201.1" else { exit(1) }
  SWIFT
end

end

timed_test("timestamp and legacy baseline selection across midnight") do
releases = (1..5).map do |version|
  {"tag_name" => "v1.0.#{version}", "assets" => [{"name" => "Lithe-1.0.#{version}-arm64.zip"}]}
end
expect(sparkle_baselines(releases.reverse, "1.0.5", "arm64").map(&:first) == %w[v1.0.4 v1.0.3 v1.0.2], "Baselines must exclude current/future versions and sort deterministically")
expect(sparkle_baselines(releases, "1.0.5", "x86_64").empty?, "Architectures must not share baselines")
puts "Baseline selection passed"

preview_release = {"tag_name" => "AutoBuild", "prerelease" => true, "assets" => %w[58.1 20261014.235959 20261015.000000 20261015.000001].map { |build| {"name" => "Lithe-preview-#{build}-arm64.zip"} }}
preview_history = [preview_release] + releases
baselines = preview_sparkle_baselines(preview_history, "20261015.000002", "arm64", "AutoBuild")
expect(baselines.map(&:last) == %w[Lithe-preview-20261015.000001-arm64.zip Lithe-preview-20261015.000000-arm64.zip Lithe-preview-20261014.235959-arm64.zip], "Select latest three timestamp builds across midnight")
expect(preview_sparkle_baselines(preview_history, "20261015.000002", "x86_64", "AutoBuild").empty?, "Never use another architecture as an AutoBuild baseline")
expect(preview_sparkle_baselines([], "20261015.000002", "arm64", "AutoBuild").empty?, "First AutoBuild uses full update")
legacy = {"tag_name" => "AutoBuild", "prerelease" => true, "assets" => [{"name" => "Lithe-preview-58.1-arm64.zip"}]}
expect(preview_sparkle_baselines([legacy], "20261015.000002", "arm64", "AutoBuild").map(&:last) == ["Lithe-preview-58.1-arm64.zip"], "Legacy numeric baselines remain readable")
%w[20261015.000001 20261014.235959 58.1 20260230.000002].each do |build|
  rejected = false
  begin
    preview_sparkle_baselines(preview_history, build, "arm64", "AutoBuild")
  rescue RuntimeError, ArgumentError
    rejected = true
  end
  expect(rejected, "Reject duplicate, backward or invalid new AutoBuild identity #{build}")
end
puts "AutoBuild timestamp packaging, legacy delta, baseline ordering and isolation passed"
end
