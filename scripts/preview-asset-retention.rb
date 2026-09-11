require "json"
require "set"
require "uri"
require "rexml/document"
require "rubygems/version"

# Only names owned by the macOS Preview publisher are eligible for deletion.
def preview_asset_build(name)
  match = /\ALithe-preview-(\d+\.\d+)-(?:arm64|x86_64)\.zip\z/.match(name) ||
    /\ALithe(\d+\.\d+)-\d+\.\d+-(?:arm64|x86_64)\.delta\z/.match(name)
  match && Gem::Version.new(match[1])
end

def preview_asset_deletions(assets, feeds, incoming_names)
  protected_names = incoming_names.to_set
  feeds.each do |xml|
    document = REXML::Document.new(xml)
    enclosures = REXML::XPath.match(document, "/rss/channel/item//enclosure")
    raise "Preview feed has no archives" if enclosures.empty?
    enclosures.each { |node| protected_names.add(File.basename(URI(node.attributes["url"].to_s).path)) }
  end
  recent_builds = assets.map { |asset| preview_asset_build(asset.fetch("name")) }
    .compact.uniq.sort.reverse.first(30).to_set
  %w[arm64 x86_64].each do |architecture|
    baselines = assets.select { |asset| asset.fetch("name").match?(/\ALithe-preview-\d+\.\d+-#{architecture}\.zip\z/) }
      .sort_by { |asset| preview_asset_build(asset.fetch("name")) }.reverse.first(3)
    baselines.each { |asset| protected_names.add(asset.fetch("name")) }
  end
  deletions = assets.select do |asset|
    name = asset.fetch("name")
    build = preview_asset_build(name)
    build && !recent_builds.include?(build) && !protected_names.include?(name)
  end
  remaining = (assets - deletions).map { |asset| asset.fetch("name") }.to_set | incoming_names.to_set
  # Leave room for other publishers sharing this release. Never evict protected
  # files or unrelated assets to make an unexpectedly large publication fit.
  raise "Preview release would exceed the 900-asset safety limit" if remaining.size > 900
  deletions
end

if $PROGRAM_NAME == __FILE__
  assets = JSON.parse(File.read(ARGV.fetch(0))).flatten(1)
  incoming = JSON.parse(File.read(ARGV.fetch(1)))
  feeds = ARGV.drop(2).map { |path| File.read(path) }
  preview_asset_deletions(assets, feeds, incoming).each do |asset|
    puts Integer(asset.fetch("id"))
  end
end
