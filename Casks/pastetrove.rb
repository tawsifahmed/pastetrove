cask "pastetrove" do
  version "0.1.1"
  sha256 "6eb9cca14a8b2994ec9c7ab220a103e2f99ad1d2045ff1ad05824dfe0e3d3a9a"

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
