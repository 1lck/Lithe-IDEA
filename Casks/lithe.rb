cask "lithe" do
  arch arm: "arm64", intel: "x86_64"

  version "0.6.4"
  sha256 arm:   "6e79b86ce0d011f14a109234c9e9a5c666dc160b84fae49ece69b463cebf336e",
         intel: "fc0132c289a925b18afe1732806adb7476073f11b6ae2c5b39ef6e64ff47b047"

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
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Lithe.app"]
  end

  uninstall quit: "app.lithe.desktop"

  zap trash: [
    "~/Library/Application Support/Lithe",
    "~/Library/Preferences/app.lithe.desktop.plist",
    "~/Library/Saved Application State/app.lithe.desktop.savedState",
  ]
end
