cask "lithe" do
  arch arm: "arm64", intel: "amd64"

  version "0.8.5"
  sha256 arm:   "ba65c70bb277d97a8c3f3b022ca5c7bb272742cdd422ec27835a23589ad5b0b7",
         intel: "04f3ca6ffbe7ff277f1d05f07899bbe8ce7be7c4532ec26206b161fec271d031"

  url "https://github.com/1lck/Lithe-IDEA/releases/download/desktop-v#{version}/lithe-#{version}-darwin-#{arch}.dmg"
  name "Lithe"
  desc "Native code editor and project workbench"
  homepage "https://github.com/1lck/Lithe-IDEA"

  livecheck do
    url :homepage
    regex(/^desktop-v?(\d+(?:\.\d+)+)$/i)
    strategy :github_latest
  end

  # The client checks the signed update feed and updates itself in place.
  auto_updates true
  depends_on macos: :ventura

  app "Lithe Desktop.app"

  # This project tap intentionally clears quarantine after the verified download.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Lithe Desktop.app"]
  end

  uninstall quit: "app.lithe.viva"

  # The first four belong to the Viva client (app.lithe.viva); the rest were left by the
  # SwiftUI client (app.lithe.desktop) that this cask installed up to 0.6.7.
  zap trash: [
    "~/Library/Application Support/Lithe Desktop",
    "~/Library/Caches/Lithe",
    "~/Library/Logs/Lithe Desktop",
    "~/Library/Saved Application State/app.lithe.viva.savedState",
    "~/Library/Application Support/Lithe",
    "~/Library/Preferences/app.lithe.desktop.plist",
    "~/Library/Saved Application State/app.lithe.desktop.savedState",
  ]
end
