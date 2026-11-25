cask "pastetrove" do
  version "0.1.4"
  sha256 "c4d699427e4067a32920d722f7030b4d1fa61c7e8a9e68fd560cdc98266dd8ee"

  url "https://github.com/tawsifahmed/pastetrove/releases/download/v#{version}/PasteTrove-#{version}.zip"
  name "PasteTrove"
  desc "Clipboard history with search, pins and three layouts"
  homepage "https://github.com/tawsifahmed/pastetrove"

  depends_on macos: :sonoma

  # PasteTrove updates itself; Homebrew leaves the installed copy to it.
  auto_updates true

  app "PasteTrove.app"

  # PasteTrove is not notarized by Apple, so Gatekeeper would refuse the
  # downloaded copy. Clear the quarantine flag on the installed app only.
  postflight_steps do
    run "/usr/bin/xattr",
        args:           ["-dr", "com.apple.quarantine", "PasteTrove.app"],
        chdir:          "{{appdir}}",
        writable_paths: ["{{appdir}}/PasteTrove.app"]
  end

  uninstall quit: "io.github.tawsifahmed.PasteTrove"

  zap trash: [
    "~/Library/Application Support/PasteTrove",
    "~/Library/Preferences/io.github.tawsifahmed.PasteTrove.plist",
  ]
end
