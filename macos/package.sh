#!/bin/sh
# Turns zig-out/Naut.app (from `zig build -Doptimize=fast`) into
# dist/Naut.dmg for people to install, and dist/Naut.zip for Check for
# Updates (which can't read a mounted image), each with a .sha256, as
# .github/workflows/release.yml publishes them.
#
#   macos/package.sh 1.2.3
#
# Signed ad hoc unless SIGN_IDENTITY names a Developer ID Application
# certificate in the keychain. With NOTARY_APPLE_ID, NOTARY_TEAM_ID and
# NOTARY_PASSWORD (an app-specific password) too, the image is notarized
# and stapled, and Gatekeeper opens it without a word.
#
# macOS remembers "may read Documents" (where the notes are) against the
# app's designated requirement. An ad hoc signature's is its code hash,
# which no two builds share: every update was a stranger that had to ask
# again. So an ad hoc build names its requirement itself, the bundle
# identifier, which every version has. A Developer ID's own requirement
# (identifier and team) already holds across versions.
set -eu

version=${1:?usage: macos/package.sh X.Y.Z}
app=zig-out/Naut.app
out=dist

plist=$app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(git rev-list --count HEAD)" "$plist"

if [ -n "${SIGN_IDENTITY:-}" ]; then
	codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
else
	id=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist")
	codesign --force --sign - --requirements "=designated => identifier \"$id\"" "$app"
	# Fails if the requirement was not taken: the hash would be back.
	codesign --display --requirements - "$app" 2>/dev/null | grep -qx "designated => identifier \"$id\""
fi
codesign --verify --strict "$app"

# The window shows the app beside a link to Applications, to drag it onto.
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$app" "$stage/Naut.app"
ln -s /Applications "$stage/Applications"

mkdir -p "$out"
hdiutil create -volname Naut -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$out/Naut.dmg"

if [ -n "${SIGN_IDENTITY:-}" ]; then
	codesign --force --timestamp --sign "$SIGN_IDENTITY" "$out/Naut.dmg"
	if [ -n "${NOTARY_APPLE_ID:-}" ]; then
		xcrun notarytool submit "$out/Naut.dmg" --wait \
			--apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD"
		xcrun stapler staple "$out/Naut.dmg"
	fi
fi

# What the updater downloads; ditto keeps the signature intact.
ditto -c -k --keepParent "$app" "$out/Naut.zip"

# The updater checks the download against these.
(cd "$out" && shasum -a 256 Naut.dmg >Naut.dmg.sha256 && shasum -a 256 Naut.zip >Naut.zip.sha256)
