#!/usr/bin/env ruby
require "tmpdir"
require "fileutils"
require "open3"
require "timeout"
require "base64"
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

tools = ARGV.fetch(0)
Dir.mktmpdir("lithe-sparkle-test-") do |root|
  @fixture_home = File.join(root, "home")
  FileUtils.mkdir_p(@fixture_home)
  key = Base64.strict_encode64("\x01" * 32)
  public_key = run("swift", "-e", 'import CryptoKit; import Foundation; print(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)).publicKey.rawRepresentation.base64EncodedString())').strip
  archives = File.join(root, "archives")
  FileUtils.mkdir_p(archives)
  originals = []
  [1, 2].each do |version|
    app = File.join(root, "v#{version}", "Lithe.app")
    originals << app
    FileUtils.mkdir_p(File.join(app, "Contents", "MacOS"))
    FileUtils.mkdir_p(File.join(app, "Contents", "Resources"))
    FileUtils.cp("/usr/bin/true", File.join(app, "Contents", "MacOS", "Lithe"))
    plist = {"CFBundleIdentifier" => "example.lithe.sparkle-fixture", "CFBundleName" => "Lithe",
      "CFBundleExecutable" => "Lithe", "CFBundlePackageType" => "APPL",
      "CFBundleVersion" => version.to_s, "CFBundleShortVersionString" => "1.0.#{version}",
      "LSMinimumSystemVersion" => "13.0", "SUPublicEDKey" => public_key,
      "SUFeedURL" => "https://example.com/appcast.xml"}
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
      run(File.join(tools, "generate_appcast"), "--ed-key-file", "-", "--versions", "1", "--download-url-prefix", "https://example.com/", archives, input: key + "\n")
      verify_sparkle_appcast(File.join(archives, "appcast.xml"), "1")
      expect(Dir.glob(File.join(archives, "*.delta")).empty?, "Bootstrap release must use a full update")
    end
  end
  feed = File.join(archives, "appcast.xml")
  File.delete(feed) # Release jobs reconstruct the feed from archived ZIPs.
  run(File.join(tools, "generate_appcast"), "--ed-key-file", "-", "--versions", "2", "--maximum-versions", "1", "--download-url-prefix", "https://example.com/", archives, input: key + "\n")
  verify_sparkle_appcast(feed, "2")
  run("ruby", File.join(__dir__, "name-sparkle-deltas.rb"), feed, "arm64")
  run(File.join(tools, "sign_update"), "--ed-key-file", "-", feed, input: key + "\n")
  run(File.join(tools, "sign_update"), "--verify", "--ed-key-file", "-", feed, input: key + "\n")
  verify_sparkle_appcast(feed, "2")
  delta = Dir.glob(File.join(archives, "*.delta")).first
  expect(delta, "Expected a usable delta for consecutive versions")
  expect(delta.end_with?("-arm64.delta"), "Delta asset names must include architecture")
  patched = File.join(root, "patched.app")
  run(File.join(tools, "BinaryDelta"), "apply", originals.first, patched, delta)
  run("diff", "-rq", originals.last, patched)
  run("codesign", "--verify", "--deep", "--strict", patched)
  item = REXML::Document.new(File.read(feed)).root.elements["channel/item"]
  enclosure = item.elements["sparkle:deltas/enclosure"]
  signature = enclosure.attributes["sparkle:edSignature"]
  run(File.join(tools, "sign_update"), "--verify", "--ed-key-file", "-", delta, signature, input: key + "\n")
  File.open(delta, "ab") { |file| file.write("corrupt") }
  run(File.join(tools, "sign_update"), "--verify", "--ed-key-file", "-", delta, signature, input: key + "\n", succeeds: false)
  expect(item.elements["enclosure"], "Full update must remain available with a delta")
  puts "Bootstrap, delta application, signature rejection, and full fallback metadata passed"
end

releases = (1..5).map do |version|
  {"tag_name" => "v1.0.#{version}", "assets" => [{"name" => "Lithe-1.0.#{version}-arm64.zip"}]}
end
expect(sparkle_baselines(releases.reverse, "1.0.5", "arm64").map(&:first) == %w[v1.0.4 v1.0.3 v1.0.2], "Baselines must exclude current/future versions and sort deterministically")
expect(sparkle_baselines(releases, "1.0.5", "x86_64").empty?, "Architectures must not share baselines")
puts "Baseline selection passed"
