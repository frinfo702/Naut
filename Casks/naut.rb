# This repository is its own tap:
#
#   brew tap frinfo702/naut https://github.com/frinfo702/Naut
#   brew install --cask naut
#
# The URL always points at the latest release, so this file needn't change
# when one is published. Naut updates itself (Naut > Check for Updates…).
cask "naut" do
  version :latest
  sha256 :no_check

  url "https://github.com/frinfo702/Naut/releases/latest/download/Naut.dmg"
  name "Naut"
  desc "Markdown notes with one-click web publishing"
  homepage "https://frinfo702.github.io/Naut/"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Naut.app"

  # Releases are signed ad hoc until they are notarized, and Gatekeeper
  # refuses a quarantined app that isn't. Official taps want
  # postflight_steps instead; third-party taps may still use postflight.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Naut.app"]
  end

  zap trash: [
    "~/Library/Preferences/com.frinfo702.naut.plist",
    "~/Library/Saved Application State/com.frinfo702.naut.savedState",
  ]
end
