require "rexml/document"
require "time"
require "rubygems"

# The two numeric components retain Sparkle ordering and legacy baseline parsing.
def autobuild_time(build, timestamp = nil)
  match = /\A(\d{4})(\d{2})(\d{2})\.(\d{2})(\d{2})(\d{2})\z/.match(build)
  raise "Invalid AutoBuild timestamp identity" unless match
  iso = "#{match[1]}-#{match[2]}-#{match[3]}T#{match[4]}:#{match[5]}:#{match[6]}Z"
  time = Time.iso8601(iso)
  raise "Invalid AutoBuild timestamp identity" unless time.utc.strftime("%Y%m%d.%H%M%S") == build
  raise "AutoBuild identity must match ISO timestamp exactly" if timestamp && timestamp != iso
  time
end

def verify_autobuild_feed(path, build, timestamp, baseline: false)
  current = autobuild_time(build, timestamp)
  document = REXML::Document.new(File.read(path))
  items = REXML::XPath.match(document, "/rss/channel/item")
  raise "Expected one AutoBuild update" unless items.length == 1
  item = items.first
  published_build = item.elements["sparkle:version"]&.text.to_s
  published_date = Time.rfc2822(item.elements["pubDate"]&.text.to_s).utc
  if baseline
    raise "Invalid AutoBuild baseline build" unless published_build.match?(/\A\d+\.\d+\z/)
    # Old feeds such as 58.1 remain readable; timestamp builds must be consistent.
    if published_build.match?(/\A\d{8}\.\d{6}\z/)
      raise "AutoBuild baseline identity/date mismatch" unless autobuild_time(published_build) == published_date
    end
    unless current > published_date && Gem::Version.new(build) > Gem::Version.new(published_build)
      raise "AutoBuild timestamp must be strictly newer than appcast baseline"
    end
  else
    raise "Wrong AutoBuild feed identity or timestamp" unless published_build == build && published_date == current
  end
end

if $PROGRAM_NAME == __FILE__
  mode = ARGV.fetch(0)
  case mode
  when "--baseline", "--feed"
    verify_autobuild_feed(ARGV.fetch(1), ARGV.fetch(2), ARGV.fetch(3), baseline: mode == "--baseline")
  when "--identity"
    autobuild_time(ARGV.fetch(1), ARGV.fetch(2))
  else
    raise "Usage: autobuild-identity.rb --identity build timestamp | --feed/--baseline appcast build timestamp"
  end
end
