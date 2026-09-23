cask "lithe" do
  arch arm: "arm64", intel: "x86_64"

  version "0.5.3"
  sha256 arm:   "6096e95be3927d411bd3f371caea5c6a200d82e448523110eed1e208a165fb33",
         intel: "00a1477234cf7b3d56816e0afc2c30a07f74203b76d69dab199c4164dc797dc2"

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
