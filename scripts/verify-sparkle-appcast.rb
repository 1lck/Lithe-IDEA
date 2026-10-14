require "rexml/document"
require "base64"
require "uri"
require "open3"

def verify_sparkle_appcast(path, build)
  document = REXML::Document.new(File.read(path))
  items = REXML::XPath.match(document, "/rss/channel/item")
  raise "Expected one current update" unless items.length == 1
  item = items.first
  raise "Wrong build version" unless item.elements["sparkle:version"]&.text == build
  full = item.elements["enclosure"]
  raise "Missing full update fallback" unless full
  REXML::XPath.match(item, ".//enclosure").each do |enclosure|
    url = URI(enclosure.attributes["url"].to_s)
    raise "Insecure update URL" unless url.scheme == "https" && url.host
    name = File.basename(url.path)
    file = File.join(File.dirname(path), name)
    raise "Missing update asset #{name}" unless File.file?(file)
    raise "Wrong asset length" unless File.size(file) == Integer(enclosure.attributes["length"])
    signature = Base64.strict_decode64(enclosure.attributes["sparkle:edSignature"].to_s)
    raise "Missing EdDSA signature" unless signature.bytesize == 64
    public_key = ENV["LITHE_SPARKLE_PUBLIC_KEY"]
    if public_key && !public_key.empty?
      output, status = Open3.capture2e("node", File.join(__dir__, "verify-release-signature.mjs"),
        file, enclosure.attributes["sparkle:edSignature"], public_key, "--inline")
      raise "Invalid archive signature: #{output}" unless status.success?
    end
  end
end

if $PROGRAM_NAME == __FILE__
  verify_sparkle_appcast(ARGV.fetch(0), ARGV.fetch(1))
  puts "Sparkle appcast verification passed"
end
