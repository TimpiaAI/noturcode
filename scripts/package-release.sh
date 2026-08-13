#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
build_dir="$repo_dir/build-distribution"
dist_dir="$repo_dir/dist"
app="$build_dir/Build/Products/Release/Noturcode.app"

command -v xcodegen >/dev/null
command -v xcodebuild >/dev/null
command -v pkgbuild >/dev/null

cd "$repo_dir"
xcodegen generate >/dev/null
xcodebuild \
  -project Noturcode.xcodeproj \
  -scheme Noturcode \
  -configuration Release \
  -derivedDataPath "$build_dir" \
  -destination 'generic/platform=macOS' \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build

application_identity=${NOTURCODE_DEVELOPER_ID_APPLICATION:--}
xattr -cr "$app"
codesign --force --deep --options runtime --timestamp --sign "$application_identity" \
  --entitlements "$repo_dir/Resources/Noturcode.entitlements" "$app"
mkdir -p "$dist_dir"
pkg_arguments=(
  --component "$app" \
  --install-location /Applications \
  --identifier ro.noturcode.installer \
  --version 0.1.0
)
if [[ -n ${NOTURCODE_DEVELOPER_ID_INSTALLER:-} ]]; then
  pkg_arguments+=(--sign "$NOTURCODE_DEVELOPER_ID_INSTALLER")
fi
pkgbuild "${pkg_arguments[@]}" "$dist_dir/Noturcode.pkg"

if [[ -n ${NOTURCODE_NOTARY_PROFILE:-} ]]; then
  xcrun notarytool submit "$dist_dir/Noturcode.pkg" --keychain-profile "$NOTURCODE_NOTARY_PROFILE" --wait
  xcrun stapler staple "$dist_dir/Noturcode.pkg"
fi

ditto -c -k --sequesterRsrc --keepParent "$app" "$dist_dir/Noturcode-macOS-universal.zip"

print "package: $dist_dir/Noturcode.pkg"
print "portable: $dist_dir/Noturcode-macOS-universal.zip"
print "architectures: $(lipo -archs "$app/Contents/MacOS/Noturcode")"
print "bridge architectures: $(lipo -archs "$app/Contents/Resources/IntegrationPayload/bin/noturcode-bridge")"
if [[ "$application_identity" == "-" ]]; then
  print "release status: local ad-hoc build; set Developer ID identities + notary profile for public distribution"
fi
