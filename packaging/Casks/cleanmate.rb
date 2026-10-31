cask "cleanmate" do
  version "1.4"
  sha256 "7da03ccda151d2128d92932437def32f787d29ad0c2fdfbf365cd952c0aee9f4"

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
