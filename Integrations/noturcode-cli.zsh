#!/bin/zsh
set -u

support_dir="$HOME/Library/Application Support/Noturcode"
bridge="$support_dir/bin/noturcode-bridge"
remote_agent="$support_dir/remote/noturcode-agent.py"

fail() {
  print -u2 -- "Noturcode: $1"
  return 1
}

step() {
  print -- ""
  print -- "[$1] $2"
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

read_host() {
  local value=""
  read "value?SSH host or alias: "
  valid_host "$value" || fail "Use one SSH host or alias without spaces." || return 1
  print -r -- "$value"
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

  step 1 "Copy the free helper to $host"
  if ! ssh "$host" 'umask 077; mkdir -p "$HOME/.local/bin"; cat > "$HOME/.local/bin/noturcode-agent"; chmod 700 "$HOME/.local/bin/noturcode-agent"' < "$remote_agent"; then
    fail "Could not copy the helper to $host."
    return 1
  fi

  step 2 "Pair with one-time code $code"
  if ! ssh -tt \
      -o ExitOnForwardFailure=yes \
      -o StreamLocalBindUnlink=yes \
      -R "${remote_socket}:${local_socket}" \
      "$host" \
      "NOTURCODE_REMOTE_SOCKET='$remote_socket' \"\$HOME/.local/bin/noturcode-agent\" pair '$code' && \"\$HOME/.local/bin/noturcode-agent\" install"; then
    fail "Pairing failed. Run nc and try again."
    return 1
  fi

  step 3 "Ready. Run nc, then choose Open an SSH workspace."
}

connect_host() {
  local host="${1:-}"
  if [[ -z "$host" ]]; then
    host=$(read_host) || return 1
  fi
  valid_host "$host" || fail "Invalid SSH host or alias." || return 1
  ensure_app || return 1

  local local_socket terminal_id remote_socket remote_command
  local_socket=$("$bridge" socket-path) || return 1
  terminal_id=$("$bridge" terminal-id) || return 1
  remote_socket="/tmp/noturcode-${USER//[^A-Za-z0-9_-]/_}-$$.sock"
  remote_command="export NOTURCODE_REMOTE_SOCKET='$remote_socket'; export NOTURCODE_TERMINAL_SESSION_ID='$terminal_id'; export NOTURCODE_REMOTE_HOST='$host'; exec \"\${SHELL:-/bin/sh}\" -l"

  step 1 "Open the encrypted tunnel"
  step 2 "Start the interactive shell on $host"
  step 3 "Run Claude, Codex, or Gemini. Use /nc NAME inside the agent."
  exec ssh -tt \
    -o ExitOnForwardFailure=yes \
    -o StreamLocalBindUnlink=yes \
    -R "${remote_socket}:${local_socket}" \
    "$host" "$remote_command"
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
    print -- "  3. Check setup"
    print -- "  4. Exit"
    local choice=""
    read "choice?Choose 1-4: "
    case "$choice" in
      1) pair_host || true ;;
      2) connect_host; return $? ;;
      3) doctor || true ;;
      4) return 0 ;;
      *) print -u2 -- "Choose 1, 2, 3, or 4." ;;
    esac
  done
}

case "${1:-}" in
  "") menu ;;
  pair) shift; pair_host "${1:-}" ;;
  ssh) shift; connect_host "${1:-}" ;;
  doctor) doctor ;;
  help|-h|--help)
    print -- "nc                 Interactive setup"
    print -- "nc pair [host]     Pair one VPS"
    print -- "nc ssh [host]      Open one tracked SSH shell"
    print -- "nc doctor          Check the local setup"
    ;;
  *) fail "Unknown command. Run nc for the guided setup." ;;
esac
