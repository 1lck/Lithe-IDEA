#!/usr/bin/env ruby

root = File.expand_path("..", __dir__)
cask_path = File.join(root, "Casks", "lithe.rb")
version = ENV.fetch("LITHE_VERSION")
arm_sha = ENV.fetch("LITHE_ARM64_SHA256").downcase
intel_sha = ENV.fetch("LITHE_X86_64_SHA256").downcase

abort "Invalid release version" unless version.match?(/\A\d+\.\d+\.\d+\z/)
abort "Invalid arm64 SHA256" unless arm_sha.match?(/\A[0-9a-f]{64}\z/)
abort "Invalid x86_64 SHA256" unless intel_sha.match?(/\A[0-9a-f]{64}\z/)

contents = File.read(cask_path)
updated = contents.sub(/^  version "[^"]+"$/, %(  version "#{version}"))
abort "Could not update the Cask version" if updated == contents

sha_pattern = /^  sha256 arm:\s+"[0-9a-f]{64}",\n         intel:\s+"[0-9a-f]{64}"$/
replacement = <<~RUBY.chomp
  sha256 arm:   "#{arm_sha}",
         intel: "#{intel_sha}"
RUBY
updated_again = updated.sub(sha_pattern, replacement)
abort "Could not update the Cask checksums" if updated_again == updated

File.write(cask_path, updated_again)
