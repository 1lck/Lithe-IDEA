cask "lithe" do
  arch arm: "arm64", intel: "x86_64"

  version "0.6.1"
  sha256 arm:   "a980acd63dce44b2ed5b8162e8dca3007d20aa57c2f523f2cd4ed83341735571",
         intel: "7fd2f434514e39370ea82c661bfa9e2eacc39aec8745ca77ba0968eccc472581"

  url "https://github.com/Lithe-IDEA/Lithe-IDEA/releases/download/v#{version}/Lithe-#{version}-#{arch}.dmg"
  name "Lithe"
  desc "Native IDE for AI-assisted Java development"
  homepage "https://github.com/Lithe-IDEA/Lithe-IDEA"

  livecheck do
    url :homepage
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "Lithe.app"

  # This project tap intentionally clears quarantine after the verified download.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Lithe.app"]
  end

  uninstall quit: "app.lithe.desktop"

  zap trash: [
    "~/Library/Application Support/Lithe",
    "~/Library/Preferences/app.lithe.desktop.plist",
    "~/Library/Saved Application State/app.lithe.desktop.savedState",
  ]
end
