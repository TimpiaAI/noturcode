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

local_signing_identity=${NOTURCODE_LOCAL_SIGNING_IDENTITY:-}
if [[ -z "$local_signing_identity" ]]; then
  local_signing_identity=$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Apple Development:[^"]*\)".*/\1/p' \
    | head -1)
fi
local_signing_identity=${local_signing_identity:--}
codesign --force --deep --sign "$local_signing_identity" \
  --entitlements "$repo_dir/Resources/Noturcode.entitlements" "$app_source"
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

# Reload only the small Noturcode provider. Never restart iTerm2 or its sessions.
# AutoLaunch keeps the provider available on later iTerm2 launches.
if [[ -x /Applications/iTerm.app/Contents/Resources/it2run ]] \
  && /bin/ps -axo command= | /usr/bin/awk \
    '$1 == "/Applications/iTerm.app/Contents/MacOS/iTerm2" { found = 1 } END { exit !found }'; then
  provider_pids=(${(f)"$(pgrep -f 'Scripts/AutoLaunch/Ask Noturcode.py' 2>/dev/null || true)"})
  for provider_pid in $provider_pids; do
    provider_command=$(/bin/ps -p "$provider_pid" -o command= 2>/dev/null || true)
    if [[ "$provider_command" == *'/Scripts/AutoLaunch/Ask Noturcode.py'* ]]; then
      /bin/kill "$provider_pid" 2>/dev/null || true
    fi
  done
  for _ in {1..20}; do
    pgrep -f 'Scripts/AutoLaunch/Ask Noturcode.py' >/dev/null || break
    sleep 0.05
  done
  /Applications/iTerm.app/Contents/Resources/it2run "$iterm_script" \
    >/tmp/noturcode-iterm-context-menu.log 2>&1 &
fi

for _ in {1..40}; do
  "$bridge_destination" doctor 2>/dev/null | grep -q '^socket: listening$' && break
  sleep 0.05
done

"$bridge_destination" doctor
print "installed app: $app_destination"
if [[ "$local_signing_identity" == "-" ]]; then
  print "local signing: ad-hoc; Automation permission can reset after each rebuild"
else
  print "local signing: stable Apple Development identity"
fi
print "installed bridge: $bridge_destination"
print "Remote SSH: run nc, then choose Open an SSH workspace"
if [[ -d "$app_backup_dir" ]]; then
  print "previous app backup: $app_backup_dir"
fi
print "Integrations were set up because this installer was run explicitly."
