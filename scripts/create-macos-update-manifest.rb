#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "pathname"

options = {
  output_directory: "dist",
  release_tag: nil
}

OptionParser.new do |parser|
  parser.banner = "Usage: create-macos-update-manifest.rb --version VERSION --repository OWNER/REPO [options]"
  parser.on("--version VERSION") { |value| options[:version] = value }
  parser.on("--repository OWNER/REPO") { |value| options[:repository] = value }
  parser.on("--release-tag TAG") { |value| options[:release_tag] = value }
  parser.on("--output-directory PATH") { |value| options[:output_directory] = value }
end.parse!

version = options[:version]
repository = options[:repository]
abort "Version must use the form MAJOR.MINOR.PATCH" unless version&.match?(/\A\d+\.\d+\.\d+\z/)
abort "Repository must use the form OWNER/REPO" unless repository&.match?(%r{\A[^/\s]+/[^/\s]+\z})

release_tag = options[:release_tag] || "v#{version}"
abort "Release tag contains unsupported characters" unless release_tag.match?(/\A[A-Za-z0-9._-]+\z/)

root = Pathname(__dir__).parent
output_directory = root.join(options[:output_directory]).cleanpath
assets = {}

%w[arm64 x86_64].each do |architecture|
  asset_name = "Lithe-#{version}-#{architecture}.dmg"
  asset_path = output_directory.join(asset_name)
  checksum_path = output_directory.join("#{asset_name}.sha256")
  abort "Missing macOS release asset: #{asset_path}" unless asset_path.file?
  abort "Missing macOS checksum: #{checksum_path}" unless checksum_path.file?

  checksum = checksum_path.read.split.first&.downcase
  abort "Invalid SHA-256 metadata: #{checksum_path}" unless checksum&.match?(/\A[0-9a-f]{64}\z/)

  actual_checksum = Digest::SHA256.file(asset_path).hexdigest
  abort "Checksum mismatch for #{asset_name}" unless checksum == actual_checksum

  assets[architecture] = {
    "url" => "https://github.com/#{repository}/releases/download/#{release_tag}/#{asset_name}",
    "sha256" => checksum
  }
end

manifest = {
  "schemaVersion" => 1,
  "version" => version,
  "releaseURL" => "https://github.com/#{repository}/releases/tag/#{release_tag}",
  "assets" => assets
}

output_directory.mkpath
manifest_path = output_directory.join("latest-macos.json")
manifest_path.write("#{JSON.pretty_generate(manifest)}\n")
puts "macOS update manifest created: #{manifest_path}"
