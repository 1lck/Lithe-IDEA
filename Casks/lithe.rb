cask "lithe" do
  arch arm: "arm64", intel: "x86_64"

  version "0.3.9"
  sha256 arm:   "a8620f7678e8ba6ad7a25295e3286289812cf831fe1dee1599549e8180587d43",
         intel: "d4a6649f6b7acbcbb8d360335108a5910befe1cded207218e88e7469c3314a58"

  url "https://github.com/1lck/Lithe-IDEA/releases/download/v#{version}/Lithe-#{version}-#{arch}.dmg"
  name "Lithe"
  desc "Native IDE for AI-assisted Java development"
  homepage "https://github.com/1lck/Lithe-IDEA"

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
