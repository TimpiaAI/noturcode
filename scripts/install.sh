#!/bin/zsh
set -euo pipefail

repo_dir=${0:A:h:h}
app_source="$repo_dir/build/Release/Noturcode.app"
app_destination="$HOME/Applications/Noturcode.app"
support_dir="$HOME/Library/Application Support/Noturcode"
bridge_destination="$support_dir/bin/noturcode-bridge"
iterm_script="$HOME/Library/Application Support/iTerm2/Scripts/AutoLaunch/Ask Noturcode.py"

command -v xcodegen >/dev/null
command -v xcodebuild >/dev/null
command -v codesign >/dev/null

cd "$repo_dir"
xcodegen generate >/dev/null
xcodebuild \
  -project Noturcode.xcodeproj \
  -target Noturcode \
  -target NoturcodeBridge \
  -configuration Release \
  ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGNING_ALLOWED=NO \
  build >/tmp/noturcode-install-build.log

codesign --force --deep --sign - --entitlements "$repo_dir/Resources/Noturcode.entitlements" "$app_source"
codesign --verify --deep --strict "$app_source"

osascript -e 'tell application id "ro.noturcode.app" to quit' 2>/dev/null || true
for _ in {1..40}; do
  pgrep -x Noturcode >/dev/null || break
  sleep 0.05
done
if pgrep -x Noturcode >/dev/null; then
  print -u2 "Noturcode is still running; nothing was replaced. Quit it and run the installer again."
  exit 1
fi
mkdir -p "$HOME/Applications" "$support_dir"

backup_stamp=$(date +%Y%m%d-%H%M%S)
app_backup_dir="$support_dir/app-backups/$backup_stamp"
staged_app="$HOME/Applications/.Noturcode.app.installing.$$"
/bin/rm -rf -- "$staged_app"
ditto "$app_source" "$staged_app"
codesign --verify --deep --strict "$staged_app"
if [[ -d "$app_destination" ]]; then
  mkdir -p "$app_backup_dir"
  mv "$app_destination" "$app_backup_dir/Noturcode.app"
fi
if ! mv "$staged_app" "$app_destination"; then
  if [[ -d "$app_backup_dir/Noturcode.app" ]]; then
    mv "$app_backup_dir/Noturcode.app" "$app_destination"
  fi
  print -u2 "Could not install Noturcode; the previous app was restored."
  exit 1
fi

# Running this source installer is an explicit request to set up integrations.
# The ordinary app launch never mutates harness configuration.
setup_output=$("$app_destination/Contents/MacOS/Noturcode" --integration-self-test "$HOME")
print -r -- "$setup_output"
if ! print -r -- "$setup_output" | grep -q '^INTEGRATION_SELF_TEST:PASS$'; then
  print -u2 "Noturcode was installed, but integration setup failed. Use Set Up or Repair Integrations from the app menu."
  exit 1
fi

open -g "$app_destination" --args --background

# Register the context-menu provider immediately without restarting iTerm2.
# AutoLaunch keeps it available on later iTerm2 launches.
if [[ -x /Applications/iTerm.app/Contents/Resources/it2run ]] \
  && pgrep -x iTerm2 >/dev/null \
  && ! pgrep -f 'Scripts/AutoLaunch/Ask Noturcode.py' >/dev/null; then
  /Applications/iTerm.app/Contents/Resources/it2run "$iterm_script" \
    >/tmp/noturcode-iterm-context-menu.log 2>&1 &
fi

for _ in {1..40}; do
  "$bridge_destination" doctor 2>/dev/null | grep -q '^socket: listening$' && break
  sleep 0.05
done

"$bridge_destination" doctor
print "installed app: $app_destination"
print "installed bridge: $bridge_destination"
print "interactive remote CLI: source '$HOME/.config/noturcode/shell.zsh' then run nc"
if [[ -d "$app_backup_dir" ]]; then
  print "previous app backup: $app_backup_dir"
fi
print "Integrations were set up because this installer was run explicitly."
