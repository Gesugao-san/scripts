#!/usr/bin/env bash
#
# play-ksp.sh - launches Kerbal Space Program through Steam and waits for it to exit.
#
# Why: Steam counts play time only when it starts the game itself,
# CKAN counts play time only while the process it started is alive.
# This wrapper satisfies both: Steam starts the game, CKAN tracks this script,
# and the script lives exactly as long as the game process does.
#
# Works with the native Linux build (KSP.x86_64) and with the Windows build
# under Proton (KSP_x64.exe).
#
# Install:
#   install -Dm755 play-ksp.sh ~/.local/bin/play-ksp
# Use: in CKAN, Play -> Edit command lines..., add the absolute path,
#   for example /home/<user>/.local/bin/play-ksp (CKAN splits the line on spaces,
#   so the path must not contain any).
#
# Exit codes: 0 - the game ran and exited; 1 - no way to reach Steam;
#             2 - the game did not start in time.

set -euo pipefail

readonly APP_ID=220200
# Exact process names (not command lines, which would also match editors,
# shells and log viewers mentioning them): native build, Windows build under Proton.
readonly GAME_PATTERN='^(KSP\.x86_64|KSP_x64\.exe)$'
# How long to wait for the game to appear: Steam start-up, Proton set-up
# and the Private Division launcher, if it shows up.
readonly START_TIMEOUT=300
readonly START_POLL=2
readonly EXIT_POLL=5

#######################################
# Asks Steam to start the game, in whatever form Steam is installed.
# Returns: 1 if no Steam was found.
#######################################
start_through_steam() {
  if command -v steam >/dev/null 2>&1; then
    steam -applaunch "$APP_ID" >/dev/null 2>&1 &
    return 0
  fi

  if command -v flatpak >/dev/null 2>&1 && flatpak info com.valvesoftware.Steam >/dev/null 2>&1; then
    flatpak run com.valvesoftware.Steam -applaunch "$APP_ID" >/dev/null 2>&1 &
    return 0
  fi

  if command -v xdg-open >/dev/null 2>&1; then
    xdg-open "steam://rungameid/$APP_ID" >/dev/null 2>&1 &
    return 0
  fi

  echo "play-ksp: Steam not found (no steam, no Flatpak Steam, no xdg-open)." >&2
  return 1
}

#######################################
# Succeeds while a game process exists.
#######################################
game_running() {
  pgrep -- "$GAME_PATTERN" >/dev/null
}

#######################################
# Waits up to START_TIMEOUT seconds for the game to appear.
# Returns: 1 on timeout.
#######################################
wait_for_start() {
  local waited=0
  until game_running; do
    if (( waited >= START_TIMEOUT )); then
      echo "play-ksp: the game did not start within ${START_TIMEOUT} s, giving up." >&2
      return 1
    fi
    sleep "$START_POLL"
    waited=$(( waited + START_POLL ))
  done
}

#######################################
# Waits until the game process is gone.
#######################################
wait_for_exit() {
  while game_running; do
    sleep "$EXIT_POLL"
  done
}

main() {
  start_through_steam || exit 1
  wait_for_start || exit 2
  wait_for_exit
}

main "$@"

