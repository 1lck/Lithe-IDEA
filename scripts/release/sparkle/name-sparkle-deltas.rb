require "rexml/document"
require "uri"

path, architecture = ARGV
raise "Invalid architecture" unless %w[arm64 x86_64].include?(architecture)
document = REXML::Document.new(File.read(path))
REXML::XPath.match(document, "/rss/channel/item/sparkle:deltas/enclosure").each do |enclosure|
  url = URI(enclosure.attributes["url"])
  old_name = File.basename(url.path)
  new_name = old_name.delete_suffix(".delta") + "-#{architecture}.delta"
  File.rename(File.join(File.dirname(path), old_name), File.join(File.dirname(path), new_name))
  url.path = File.join(File.dirname(url.path), new_name)
  enclosure.attributes["url"] = url.to_s
end
# The caller re-signs the feed after changing URLs; archive signatures stay valid.
File.write(path, document.to_s)
