cask "pastetrove" do
  version "0.1.0"
  sha256 "24a3df9f962a4245023d054895fe9610d179b597bac1eec05758b6b1d60d350d"

  url "https://github.com/tawsifahmed/pastetrove/releases/download/v#{version}/PasteTrove-#{version}.zip"
  name "PasteTrove"
  desc "Clipboard history with search, pins and three layouts"
  homepage "https://github.com/tawsifahmed/pastetrove"

  depends_on macos: :sonoma

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
