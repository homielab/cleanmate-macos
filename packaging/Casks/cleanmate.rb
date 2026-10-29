cask "cleanmate" do
  version "1.3"
  sha256 "ed420f396e4bace93289148646de436f699f1541bb9991be0fa27a23dc0572cf"

  url "https://github.com/homielab/cleanmate/releases/download/v#{version}/CleanMate-#{version}.dmg"
  name "CleanMate"
  desc "Cleaner for developers: system and developer junk, uninstaller, large files"
  homepage "https://github.com/homielab/cleanmate"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :ventura

  app "CleanMate.app"

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
