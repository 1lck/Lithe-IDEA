cask "lithe" do
  arch arm: "arm64", intel: "x86_64"

  version "0.1.12"
  sha256 arm:   "548c2083df048fdf5390f5e1cd1f1676b37ba4b23720990c690680220edc3afa",
         intel: "0d37cd94c75aa46c679a72ea4ad41d929c0c9782cf422f221395d45ae5ae4fbb"

  url "https://github.com/1lck/Lithe-IDEA/releases/download/v#{version}/Lithe-#{version}-#{arch}.dmg"
  name "Lithe"
  desc "Native IDE for AI-assisted Java development"
  homepage "https://github.com/1lck/Lithe-IDEA"

  livecheck do
    url :homepage
    strategy :github_latest
  end

  depends_on macos: :sonoma

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
