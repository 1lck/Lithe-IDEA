cask "lithe" do
  arch arm: "arm64", intel: "x86_64"

  version "0.4.8"
  sha256 arm:   "319d5c1a4d6a4e38cd98c54b5c7a8c2467e7bca3e1628991ec4e8b7d6e1069fc",
         intel: "d83d7fc1b8802280ccccc16e0ae78ee2023fcf4ad7306075cff9e9fe04bd776f"

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
