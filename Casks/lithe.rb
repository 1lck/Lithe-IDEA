cask "lithe" do
  arch arm: "arm64", intel: "amd64"

  version "0.8.1"
  sha256 arm:   "ef86dbd3eb85be1bca5966ef0473785e5d093abef95bd76d01f0e42d29d6abdc",
         intel: "4b09e082b65dd52d82198c578dd395479edffc4d2e54bdeeb858caab5092d1d8"

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
