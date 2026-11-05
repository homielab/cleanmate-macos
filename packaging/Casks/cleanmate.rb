cask "cleanmate" do
  version "1.8"
  sha256 "8f96385565cc88ce8478a85c4eb1904dc8fa02a1afac90113f3e1f2fb8a357d2"

  url "https://github.com/homielab/cleanmate-macos/releases/download/v#{version}/CleanMate-#{version}.dmg"
  name "CleanMate"
  desc "Cleaner for developers: system and developer junk, uninstaller, large files"
  homepage "https://github.com/homielab/cleanmate-macos"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :ventura

  app "CleanMate.app"
  binary "#{appdir}/CleanMate.app/Contents/Helpers/cleanmate"

  zap trash: [
    "~/Library/Application Support/com.homielab.CleanMate",
    "~/Library/Caches/com.homielab.CleanMate",
    "~/Library/HTTPStorages/com.homielab.CleanMate",
    "~/Library/HTTPStorages/com.homielab.CleanMate.binarycookies",
    "~/Library/Logs/CleanMate",
    "~/Library/Preferences/com.homielab.CleanMate.plist",
    "~/Library/Saved Application State/com.homielab.CleanMate.savedState",
  ]
end
