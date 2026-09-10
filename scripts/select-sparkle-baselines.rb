require "json"
require "rubygems"

def sparkle_baselines(releases, version, architecture)
  raise "Invalid architecture" unless %w[arm64 x86_64].include?(architecture)
  current = Gem::Version.new(version)
  releases.map do |release|
    tag = release.fetch("tag_name")
    next if release["draft"] || release["prerelease"] || !tag.match?(/\Av\d+\.\d+\.\d+\z/)
    candidate = Gem::Version.new(tag.delete_prefix("v"))
    next unless candidate < current
    name = "Lithe-#{candidate}-#{architecture}.zip"
    next unless release.fetch("assets").any? { |asset| asset["name"] == name }
    [candidate, tag, name]
  end.compact.sort_by(&:first).reverse.first(3).map { |_, tag, name| [tag, name] }
end

if $PROGRAM_NAME == __FILE__
  sparkle_baselines(JSON.parse(File.read(ARGV.fetch(0))), ARGV.fetch(1), ARGV.fetch(2)).each do |entry|
    puts entry.join("\t")
  end
end
