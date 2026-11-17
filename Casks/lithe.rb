cask "lithe" do
  arch arm: "arm64", intel: "amd64"

  version "0.8.3"
  sha256 arm:   "09e1c0bd3d0aa355d12915740dd2f3ff3ecec052160001bb6e4bea7af2e5d7c3",
         intel: "c621be499a1707ae02954154bdb8a0f0a79f19e6f720fdf1c3db2a188ca74720"

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
