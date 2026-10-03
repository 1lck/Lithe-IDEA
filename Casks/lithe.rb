cask "lithe" do
  arch arm: "arm64", intel: "x86_64"

  version "0.5.12"
  sha256 arm:   "c7fd505d67987c5fecb94e3f2fa82f7ecccfe98fb63b5f9b1ff18c2c6b149b48",
         intel: "e6487dc56ae0fa180c4c4a59c31eeeab05a449e5dc18bd23a68a4af0085c2d3d"

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
