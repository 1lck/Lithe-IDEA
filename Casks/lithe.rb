cask "lithe" do
  arch arm: "arm64", intel: "x86_64"

  version "0.4.4"
  sha256 arm:   "aba0ebbf8c31f0917ff00b82e275322fc6c9d19a1709e5c6fb3d684ca5a3d6f0",
         intel: "5db9d3c826fa8b4005fc2fab8bbfdbfe278d9d8472f1c91b0c0565a9e941a356"

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
