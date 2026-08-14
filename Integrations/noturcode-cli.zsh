#!/bin/zsh
set -u

support_dir="$HOME/Library/Application Support/Noturcode"
bridge="$support_dir/bin/noturcode-bridge"
remote_agent="$support_dir/remote/noturcode-agent.py"
active_proxy_pid=""
active_proxy_socket=""

fail() {
  print -u2 -- "Noturcode: $1"
  return 1
}

step() {
  print -- ""
  print -- "[$1] $2"
}

settle() {
  local label="$1"
  if [[ -t 1 ]]; then
    local frame
    for frame in '[>   ]' '[=>  ]' '[==> ]' '[===>]'; do
      printf '\r  %s %s' "$frame" "$label"
      sleep 0.025
    done
    printf '\r  [ ok ] %s\n' "$label"
  else
    print -- "  [ ok ] $label"
  fi
}

valid_host() {
  [[ -n "$1" && "$1" != -* && "$1" != *[$'\n\r\t ']* ]]
}

ensure_app() {
  [[ -x "$bridge" ]] || fail "Install Noturcode.app first." || return 1
  if "$bridge" doctor 2>/dev/null | grep -q '^socket: listening$'; then
    return 0
  fi
  local app=""
  for candidate in "/Applications/Noturcode.app" "$HOME/Applications/Noturcode.app"; do
    if [[ -d "$candidate" ]]; then
      app="$candidate"
      break
    fi
  done
  [[ -n "$app" ]] || fail "Noturcode.app was not found." || return 1
  open -g "$app" --args --background
  local attempt
  for attempt in {1..40}; do
    "$bridge" doctor 2>/dev/null | grep -q '^socket: listening$' && return 0
    sleep 0.05
  done
  fail "Noturcode.app did not start."
}

stop_proxy() {
  if [[ -n "$active_proxy_pid" ]]; then
    kill "$active_proxy_pid" 2>/dev/null || true
    wait "$active_proxy_pid" 2>/dev/null || true
    active_proxy_pid=""
  fi
  if [[ -n "$active_proxy_socket" ]]; then
    rm -f -- "$active_proxy_socket"
    active_proxy_socket=""
  fi
}

start_proxy() {
  local target_socket="$1"
  local label="$2"
  active_proxy_socket="/tmp/noturcode-${USER//[^A-Za-z0-9_-]/_}-${label}-proxy-$$.sock"
  "$remote_agent" proxy --listen "$active_proxy_socket" --target "$target_socket" &
  active_proxy_pid=$!
  local attempt
  for attempt in {1..40}; do
    [[ -S "$active_proxy_socket" ]] && return 0
    kill -0 "$active_proxy_pid" 2>/dev/null || break
    sleep 0.05
  done
  stop_proxy
  fail "Could not start the secure local SSH proxy."
}

read_host() {
  local value=""
  read "value?SSH host or alias: "
  valid_host "$value" || fail "Use one SSH host or alias without spaces." || return 1
  print -r -- "$value"
}

read_chat_name() {
  local default_name="$1"
  local value=""
  read "value?Chat name [$default_name]: "
  value="${value:-$default_name}"
  if [[ -z "$value" || ${#value} -gt 80 || "$value" == *[$'\n\r\t']* || "$value" == *"'"* ]]; then
    fail "Use 1-80 characters. Do not use quotes or line breaks."
    return 1
  fi
  print -r -- "$value"
}

sync_remote_agent() {
  local host="$1"
  ssh "$host" 'umask 077; mkdir -p "$HOME/.local/bin"; cat > "$HOME/.local/bin/noturcode-agent"; chmod 700 "$HOME/.local/bin/noturcode-agent"' < "$remote_agent"
}

pair_host() {
  local host="${1:-}"
  if [[ -z "$host" ]]; then
    host=$(read_host) || return 1
  fi
  valid_host "$host" || fail "Invalid SSH host or alias." || return 1
  [[ -r "$remote_agent" ]] || fail "The remote helper is missing. Repair Noturcode integrations." || return 1
  ensure_app || return 1

  local local_socket code remote_socket
  local_socket=$("$bridge" socket-path) || return 1
  code=$("$bridge" pair-code --host "$host") || return 1
  remote_socket="/tmp/noturcode-${USER//[^A-Za-z0-9_-]/_}-pair-$$.sock"
  start_proxy "$local_socket" pair || return 1

  step 1 "Copy the free helper to $host"
  if ! sync_remote_agent "$host"; then
    stop_proxy
    fail "Could not copy the helper to $host."
    return 1
  fi
  settle "Helper copied"

  step 2 "Pair with one-time code $code"
  if ! ssh -tt \
      -o ExitOnForwardFailure=yes \
      -o StreamLocalBindUnlink=yes \
      -R "${remote_socket}:${active_proxy_socket}" \
      "$host" \
      "NOTURCODE_REMOTE_SOCKET='$remote_socket' \"\$HOME/.local/bin/noturcode-agent\" pair '$code' && \"\$HOME/.local/bin/noturcode-agent\" install"; then
    stop_proxy
    fail "Pairing failed. Run nc and try again."
    return 1
  fi
  stop_proxy
  settle "VPS paired"

  step 3 "Ready. Run nc, then choose Open an SSH workspace."
}

connect_host() {
  local host="${1:-}"
  local mode="${2:-shell}"
  local chat_name="${3:-}"
  if [[ -z "$host" ]]; then
    host=$(read_host) || return 1
  fi
  valid_host "$host" || fail "Invalid SSH host or alias." || return 1
  if [[ -z "$chat_name" ]]; then
    chat_name=$(read_chat_name "$host") || return 1
  fi
  ensure_app || return 1

  step 1 "Sync the remote helper on $host"
  if ! sync_remote_agent "$host"; then
    fail "Could not update the helper on $host."
    return 1
  fi
  settle "Helper ready"

  local local_socket terminal_id remote_socket remote_command
  local_socket=$("$bridge" socket-path) || return 1
  terminal_id=$("$bridge" terminal-id) || return 1
  remote_socket="/tmp/noturcode-${USER//[^A-Za-z0-9_-]/_}-$$.sock"
  if [[ "$mode" == "resume" ]]; then
    remote_command="export NOTURCODE_REMOTE_SOCKET='$remote_socket'; export NOTURCODE_TERMINAL_SESSION_ID='$terminal_id'; export NOTURCODE_REMOTE_HOST='$host'; export NOTURCODE_SESSION_NAME='$chat_name'; exec \"\${SHELL:-/bin/sh}\" -lc 'codex resume --all'"
  else
    remote_command="export NOTURCODE_REMOTE_SOCKET='$remote_socket'; export NOTURCODE_TERMINAL_SESSION_ID='$terminal_id'; export NOTURCODE_REMOTE_HOST='$host'; export NOTURCODE_SESSION_NAME='$chat_name'; exec \"\${SHELL:-/bin/sh}\" -l"
  fi
  start_proxy "$local_socket" session || return 1

  step 2 "Open the encrypted tunnel"
  settle "Tunnel ready"
  if [[ "$mode" == "resume" ]]; then
    step 3 "Open the Codex chat picker on $host"
    step 4 "Select a chat. Noturcode will show it as $chat_name."
  else
    step 3 "Start the interactive shell on $host"
    step 4 "Run your coding agent. Noturcode will show it as $chat_name."
  fi
  ssh -tt \
    -o ExitOnForwardFailure=yes \
    -o StreamLocalBindUnlink=yes \
    -R "${remote_socket}:${active_proxy_socket}" \
    "$host" "$remote_command"
  local status=$?
  stop_proxy
  return "$status"
}

resume_codex() {
  local host="${1:-}"
  local chat_name="${2:-}"
  if [[ -z "$host" ]]; then
    host=$(read_host) || return 1
  fi
  connect_host "$host" resume "$chat_name"
}

doctor() {
  ensure_app || return 1
  "$bridge" doctor
  print -- "cli: nc"
  print -- "remote helper: $([[ -r "$remote_agent" ]] && print ready || print missing)"
}

menu() {
  while true; do
    print -- ""
    print -- "Noturcode remote"
    print -- "  1. Pair a VPS"
    print -- "  2. Open an SSH workspace"
    print -- "  3. Resume an existing Codex chat"
    print -- "  4. Check setup"
    print -- "  5. Exit"
    local choice=""
    read "choice?Choose 1-5: "
    case "$choice" in
      1) pair_host || true ;;
      2) connect_host; return $? ;;
      3) resume_codex; return $? ;;
      4) doctor || true ;;
      5) return 0 ;;
      *) print -u2 -- "Choose 1, 2, 3, 4, or 5." ;;
    esac
  done
}

case "${1:-}" in
  "") menu ;;
  pair) shift; pair_host "${1:-}" ;;
  ssh) shift; connect_host "${1:-}" shell "${2:-}" ;;
  resume) shift; resume_codex "${1:-}" "${2:-}" ;;
  doctor) doctor ;;
  help|-h|--help)
    print -- "nc                 Interactive setup"
    print -- "nc pair [host]     Pair one VPS"
    print -- "nc ssh [host]      Open one tracked SSH shell"
    print -- "nc resume [host]   Resume an existing Codex chat"
    print -- "nc doctor          Check the local setup"
    ;;
  *) fail "Unknown command. Run nc for the guided setup." ;;
esac
