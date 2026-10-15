require "rexml/document"
require_relative "autobuild-identity"

path, timestamp, build = ARGV
time = autobuild_time(build, timestamp)
date = time.rfc2822
document = REXML::Document.new(File.read(path))
items = REXML::XPath.match(document, "/rss/channel/item")
raise "Expected one Preview build" unless items.length == 1
item = items.first
(item.elements["pubDate"] || item.add_element("pubDate")).text = date
(item.elements["title"] || item.add_element("title")).text = "AutoBuild — 构建自 #{time.strftime("%Y-%m-%d %H:%M:%S")} UTC"
# The publisher signs the final XML after all metadata changes.
File.write(path, document.to_s)
