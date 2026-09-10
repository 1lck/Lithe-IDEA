#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "json"
require "optparse"
require "pathname"
require "time"
require "base64"

options = {
  output_directory: "dist",
  release_tag: nil,
  release_notes_path: nil,
  release_date: nil
}

OptionParser.new do |parser|
  parser.banner = "Usage: create-macos-update-manifest.rb --version VERSION --repository OWNER/REPO [options]"
  parser.on("--version VERSION") { |value| options[:version] = value }
  parser.on("--repository OWNER/REPO") { |value| options[:repository] = value }
  parser.on("--release-tag TAG") { |value| options[:release_tag] = value }
  parser.on("--release-notes-path PATH") { |value| options[:release_notes_path] = value }
  parser.on("--release-date DATE") { |value| options[:release_date] = value }
  parser.on("--output-directory PATH") { |value| options[:output_directory] = value }
  parser.on("--require-signatures") { options[:require_signatures] = true }
end.parse!

version = options[:version]
repository = options[:repository]
abort "Version must use the form MAJOR.MINOR.PATCH" unless version&.match?(/\A\d+\.\d+\.\d+\z/)
abort "Repository must use the form OWNER/REPO" unless repository&.match?(%r{\A[^/\s]+/[^/\s]+\z})

release_tag = options[:release_tag] || "v#{version}"
abort "Release tag contains unsupported characters" unless release_tag.match?(/\A[A-Za-z0-9._-]+\z/)

root = Pathname(__dir__).parent
output_directory = root.join(options[:output_directory]).cleanpath
release_notes = if options[:release_notes_path]
  notes_path = root.join(options[:release_notes_path]).cleanpath
  abort "Missing release notes: #{notes_path}" unless notes_path.file?

  notes_path.read
end
release_date = options[:release_date] || Time.now.utc.iso8601
abort "Release date must be ISO-8601" unless Time.iso8601(release_date)
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
  signature_path = output_directory.join("#{asset_name}.edsig")
  if signature_path.file?
    signature = signature_path.read.strip
    abort "Invalid Ed25519 signature for #{asset_name}" unless Base64.strict_decode64(signature).bytesize == 64
    assets[architecture]["edSignature"] = signature
  elsif options[:require_signatures]
    abort "Missing publisher signature for #{asset_name}"
  end
end

manifest = {
  "schemaVersion" => 1,
  "version" => version,
  "releaseDate" => release_date,
  "releaseNotes" => release_notes,
  "releaseURL" => "https://github.com/#{repository}/releases/tag/#{release_tag}",
  "assets" => assets
}

output_directory.mkpath
manifest_path = output_directory.join("latest-macos.json")
manifest_path.write("#{JSON.pretty_generate(manifest)}\n")
puts "macOS update manifest created: #{manifest_path}"
