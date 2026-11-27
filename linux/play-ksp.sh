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
# Second mode, the other way round: Steam's Play button opens CKAN.
#   Steam -> KSP -> Properties -> Launch options:
#     ~/.local/bin/play-ksp --from-steam %command%
#   Steam then still starts its own reaper (which counts play time) and
#   steam-launch-wrapper, but CKAN runs in place of the game, outside the
#   Steam Linux Runtime and Proton. Steam counts the whole time CKAN is open.
#   Inside CKAN, start the game with the native line (./KSP.x86_64), not with
#   play-ksp: Steam already considers KSP running.
#   The CKAN command is taken from $CKAN_CMD (default: ckan). Steam's full
#   command line is logged to ~/.cache/play-ksp/steam-command.log.
#
# Exit codes: 0 - the game ran and exited; 1 - no way to reach Steam;
#             2 - the game did not start in time; 3 - CKAN not found.

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

#######################################
# Prints how many leading words of Steam's %command% to keep: the reaper and
# steam-launch-wrapper with their "--" separators, without the runtime, Proton
# or the game behind them. Prints 0 when there is nothing recognisable.
# Arguments: Steam's %command%, word by word.
#######################################
steam_prefix_length() {
  local -a words=("$@")
  local i wrapper=-1 reaper_end=-1

  for i in "${!words[@]}"; do
    case "${words[i]}" in
      */steam-launch-wrapper) wrapper=$i ;;
      --) (( reaper_end < 0 )) && reaper_end=$i ;;
    esac
  done

  # Keep up to the "--" right after steam-launch-wrapper.
  if (( wrapper >= 0 )); then
    for (( i = wrapper + 1; i < ${#words[@]}; i++ )); do
      if [[ ${words[i]} == -- ]]; then
        echo $(( i + 1 ))
        return
      fi
    done
  fi

  # No launch wrapper: keep the reaper part only.
  if (( reaper_end >= 0 )); then
    echo $(( reaper_end + 1 ))
    return
  fi

  echo 0
}

#######################################
# Runs CKAN in place of the game inside Steam's launch chain.
# Arguments: Steam's %command%, word by word.
#######################################
run_ckan_from_steam() {
  local ckan=${CKAN_CMD:-ckan}
  if ! command -v "$ckan" >/dev/null 2>&1; then
    echo "play-ksp: CKAN command '$ckan' not found; set CKAN_CMD." >&2
    exit 3
  fi

  local log_dir=${XDG_CACHE_HOME:-$HOME/.cache}/play-ksp
  mkdir -p "$log_dir"
  {
    printf '%s' "$(date -Is)"
    printf ' %q' "$@"
    echo
  } >>"$log_dir/steam-command.log"

  local keep
  keep=$(steam_prefix_length "$@")
  # The Steam runtime's libraries must not leak into CKAN (Mono or .NET).
  exec "${@:1:keep}" env -u LD_LIBRARY_PATH -u LD_PRELOAD "$(command -v "$ckan")"
}

main() {
  if [[ ${1:-} == --from-steam ]]; then
    shift
    run_ckan_from_steam "$@"
  fi

  start_through_steam || exit 1
  wait_for_start || exit 2
  wait_for_exit
}

main "$@"

