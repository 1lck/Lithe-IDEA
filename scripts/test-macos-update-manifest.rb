#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "open3"
require "pathname"
require "tmpdir"

root = Pathname(__dir__).parent
generator = root.join("scripts/create-macos-update-manifest.rb")
version = "9.8.7"

Dir.mktmpdir("lithe-macos-manifest-") do |directory|
  output = Pathname(directory)
  %w[arm64 x86_64].each do |architecture|
    asset = output.join("Lithe-#{version}-#{architecture}.dmg")
    asset.write("test #{architecture} disk image")
    output.join("#{asset.basename}.sha256").write("#{Digest::SHA256.file(asset).hexdigest}  #{asset.basename}\n")
  end

  existing_manifest = output.join("latest.json")
  existing_manifest.write(JSON.generate(
    "version" => version,
    "notes" => "Windows release notes",
    "platforms" => {
      "windows-x86_64" => {
        "signature" => "test-signature",
        "url" => "https://github.com/example/Lithe-IDEA/releases/download/v#{version}/windows.exe"
      }
    }
  ))

  relative_output = output.relative_path_from(root).to_s
  stdout, stderr, status = Open3.capture3(
    generator.to_s,
    "--version", version,
    "--repository", "example/Lithe-IDEA",
    "--output-directory", relative_output,
    chdir: root.to_s
  )
  abort "Generator failed: #{stdout}#{stderr}" unless status.success?

  manifest = JSON.parse(output.join("latest-macos.json").read)
  raise "Schema version is incorrect" unless manifest["schemaVersion"] == 1
  raise "Release URL is incorrect" unless manifest["releaseURL"] == "https://github.com/example/Lithe-IDEA/releases/tag/v#{version}"
  windows_manifest = JSON.parse(existing_manifest.read)
  raise "Windows manifest was modified" unless windows_manifest.dig("platforms", "windows-x86_64", "signature") == "test-signature"
  raise "macOS manifest contains Windows metadata" if manifest.key?("platforms")

  %w[arm64 x86_64].each do |architecture|
    asset = output.join("Lithe-#{version}-#{architecture}.dmg")
    entry = manifest.dig("assets", architecture)
    expected_url = "https://github.com/example/Lithe-IDEA/releases/download/v#{version}/#{asset.basename}"
    raise "#{architecture} URL is incorrect" unless entry["url"] == expected_url
    raise "#{architecture} checksum is incorrect" unless entry["sha256"] == Digest::SHA256.file(asset).hexdigest
  end

  output.join("Lithe-#{version}-arm64.dmg.sha256").write("#{"0" * 64}  invalid.dmg\n")
  _stdout, _stderr, invalid_status = Open3.capture3(
    generator.to_s,
    "--version", version,
    "--repository", "example/Lithe-IDEA",
    "--output-directory", relative_output,
    chdir: root.to_s
  )
  raise "Generator accepted a checksum mismatch" if invalid_status.success?
end

puts "macOS update manifest test passed."
