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

def preview_sparkle_baselines(releases, build, architecture, tag)
  raise "Invalid architecture" unless %w[arm64 x86_64].include?(architecture)
  raise "Invalid preview build" unless build.match?(/\A\d+\.\d+\z/)
  current = Gem::Version.new(build)
  release = releases.find { |item| item["tag_name"] == tag && item["prerelease"] && !item["draft"] }
  return [] unless release
  candidates = release.fetch("assets").map do |asset|
    match = /\ALithe-preview-(\d+\.\d+)-#{Regexp.escape(architecture)}\.zip\z/.match(asset["name"])
    next unless match
    version = Gem::Version.new(match[1])
    raise "Preview build must be newer than every published build" if version >= current
    [version, tag, asset["name"]]
  end.compact
  candidates.sort_by(&:first).reverse.first(3).map { |_, release_tag, name| [release_tag, name] }
end

if $PROGRAM_NAME == __FILE__
  releases = JSON.parse(File.read(ARGV.fetch(0)))
  entries = if ARGV[3] == "preview"
    preview_sparkle_baselines(releases, ARGV.fetch(1), ARGV.fetch(2), ARGV.fetch(4))
  else
    sparkle_baselines(releases, ARGV.fetch(1), ARGV.fetch(2))
  end
  entries.each do |entry|
    puts entry.join("\t")
  end
end
