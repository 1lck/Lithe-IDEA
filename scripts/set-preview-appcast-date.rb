require "rexml/document"
require "time"

path, timestamp = ARGV
date = Time.iso8601(timestamp).utc.rfc2822
document = REXML::Document.new(File.read(path))
items = REXML::XPath.match(document, "/rss/channel/item")
raise "Expected one Preview build" unless items.length == 1
item = items.first
(item.elements["pubDate"] || item.add_element("pubDate")).text = date
# The publisher signs the final XML after all metadata changes.
File.write(path, document.to_s)
