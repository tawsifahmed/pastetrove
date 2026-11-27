cask "pastetrove" do
  version "1.0.0"
  sha256 "0759c5c98cbc37e73c6a68797eabd391bed677f35caa87c6872c23a59b95dbb4"

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
