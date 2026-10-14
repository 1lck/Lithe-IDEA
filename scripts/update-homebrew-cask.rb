#!/usr/bin/env ruby

root = File.expand_path("..", __dir__)
cask_path = File.join(root, "Casks", "lithe.rb")
repository = ENV.fetch("GITHUB_REPOSITORY", "1lck/Lithe-IDEA")
abort "Invalid release repository" unless repository.match?(%r{\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z})
version = ENV.fetch("LITHE_VERSION")
arm_sha = ENV.fetch("LITHE_ARM64_SHA256").downcase
intel_sha = ENV.fetch("LITHE_X86_64_SHA256").downcase

abort "Invalid release version" unless version.match?(/\A\d+\.\d+\.\d+\z/)
abort "Invalid arm64 SHA256" unless arm_sha.match?(/\A[0-9a-f]{64}\z/)
abort "Invalid x86_64 SHA256" unless intel_sha.match?(/\A[0-9a-f]{64}\z/)

contents = File.read(cask_path)
version_pattern = /^  version "[^"]+"$/
abort "Could not find the Cask version" unless contents.match?(version_pattern)
updated = contents.sub(version_pattern, %(  version "#{version}"))

sha_pattern = /^  sha256 arm:\s+"[0-9a-f]{64}",\n         intel:\s+"[0-9a-f]{64}"$/
abort "Could not find the Cask checksums" unless updated.match?(sha_pattern)
replacement = %(  sha256 arm:   "#{arm_sha}",\n         intel: "#{intel_sha}")
updated_again = updated.sub(sha_pattern, replacement)

# URLs and checksums must refer to the same repository's published assets.
url_pattern = /^  url "[^"]+"$/
homepage_pattern = /^  homepage "[^"]+"$/
abort "Could not find the Cask download URL" unless updated_again.match?(url_pattern)
abort "Could not find the Cask homepage" unless updated_again.match?(homepage_pattern)
updated_again = updated_again.sub(url_pattern, '  url "https://github.com/' + repository + '/releases/download/v#{version}/Lithe-#{version}-#{arch}.dmg"')
updated_again = updated_again.sub(homepage_pattern, %(  homepage "https://github.com/#{repository}"))
File.write(cask_path, updated_again) if updated_again != contents
