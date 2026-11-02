cask "cleanmate" do
  version "1.6"
  sha256 "5f0b5a1dd21078ebefb545572995051059e0cbeb4d50c0ad0583fdf3b499c6ae"

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
