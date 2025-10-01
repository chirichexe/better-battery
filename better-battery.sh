#!/usr/bin/env bash

# MIT License
#
# Copyright (c) 2025 Davide Chirichella
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

set -euo pipefail
IFS=$'\n\t'

PROG_NAME="battery-notify"
VERSION="1.0"

# defaults (can be overridden by config file)
: ${CONFIG_PATH:="$HOME/.config/battery-notify.conf"}

# load default values (inline defaults if no config file provided)
SOUND_AC_CONNECTED="$HOME/.local/share/sounds/battery/ac_connected.mp3"
SOUND_AC_DISCONNECTED="$HOME/.local/share/sounds/battery/ac_disconnected.mp3"
SOUND_LOW="$HOME/.local/share/sounds/battery/low.mp3"
SOUND_CRITICAL="$HOME/.local/share/sounds/battery/critical.mp3"
SOUND_HIGH="$HOME/.local/share/sounds/battery/high.mp3"
PLAYER_CMD="mpg123"
THRESHOLD_LOW=20
THRESHOLD_CRITICAL=10
THRESHOLD_HIGH=80
MIN_DELTA=1
LOG_TO="stdout"
UPower_DBUS_SERVICE="org.freedesktop.UPower"
AC_PATH=""
BAT_PATH=""

EMOJI_CHARGER="󰂄"
EMOJI_BATTERY_LOW="󰁻"
EMOJI_BATTERY_CRITICAL="󰂃"
EMOJI_BATTERY_OK="󱟢"

PIDFILE="/run/user/$(id -u)/${PROG_NAME}.pid"

# Helper: print to logger or stdout
log() {
  local msg="$*"
  if [[ "$LOG_TO" == "syslog" ]]; then
    logger -t "$PROG_NAME" -- "$msg"
  else
    printf '%s %s\n' "[$(date +'%Y-%m-%dT%H:%M:%S%z')]" "$msg"
  fi
}

usage() {
  cat <<EOF
$PROG_NAME $VERSION

Usage: $0 [--config /path/to/conf] [--help]

Options:
  --config PATH    Use PATH as config (default: $CONFIG_PATH)
  --help           Show this help
EOF
}

# simple arg parsing
while [[ ${1-} != "" ]]; do
  case "$1" in
  --config)
    shift
    CONFIG_PATH="$1"
    shift
    ;;
  --help)
    usage
    exit 0
    ;;
  -h)
    usage
    exit 0
    ;;
  *)
    echo "Unknown arg: $1"
    usage
    exit 2
    ;;
  esac
done

# load config if present
if [[ -f "$CONFIG_PATH" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG_PATH"
  log "Loaded config from $CONFIG_PATH"
fi

# ensure single instance per user
mkdir -p "$(dirname "$PIDFILE")"
if [[ -f "$PIDFILE" ]]; then
  oldpid=$(<"$PIDFILE") || true
  if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
    log "Another instance is running (PID $oldpid). Exiting."
    exit 0
  else
    log "Stale PID file found, replacing."
  fi
fi
printf '%s' "$$" >"$PIDFILE"
trap 'rm -f "$PIDFILE"; exit' INT TERM EXIT

# dependency checks
for cmd in gdbus upower notify-send; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "Missing dependency: $cmd. Aborting."
    exit 2
  fi
done

PLAYER_BIN=""
if [[ -n "$PLAYER_CMD" ]]; then
  PLAYER_BIN=${PLAYER_CMD%% *}
  if ! command -v "$PLAYER_BIN" >/dev/null 2>&1; then
    log "Note: audio player '$PLAYER_BIN' not found; sounds disabled."
    PLAYER_CMD=""
  fi
fi

# auto-detect device paths via upower
auto_detect_paths() {
  if [[ -n "$AC_PATH" && -n "$BAT_PATH" ]]; then
    return 0
  fi
  local devices
  devices=$(upower -e 2>/dev/null || true)
  for dev in $devices; do
    [[ "$dev" == *line_power* ]] && AC_PATH="$dev"
    [[ "$dev" == *battery* || "$dev" == *DisplayDevice* ]] && BAT_PATH="$dev"
  done
  # sensible defaults if detection fails
  : ${AC_PATH:="/org/freedesktop/UPower/devices/line_power_AC"}
  : ${BAT_PATH:="/org/freedesktop/UPower/devices/battery_BAT1"}
}

notify_and_play() {
  local title="$1"
  local body="$2"
  local sound="$3"
  # send notification; do not fail script if notify-send fails
  notify-send "$title" "$body" || true
  if [[ -n "$sound" && -f "$sound" && -n "$PLAYER_CMD" ]]; then
    # play in background, redirect output
    $PLAYER_CMD "$sound" >/dev/null 2>&1 &
  fi
}

# get battery percentage (integer)
get_battery_percentage() {
  local bat="$1"
  # use upower -i and awk for robust parsing
  upower -i "$bat" 2>/dev/null | awk -F: '/percentage:/ {gsub(/%| /, "", $2); print int($2); exit}' || true
}

# absolute difference
absdiff() {
  local a=$1 b=$2
  if ((a >= b)); then echo $((a - b)); else echo $((b - a)); fi
}

# start
log "Starting $PROG_NAME"

auto_detect_paths
log "UPower listener started. AC=$AC_PATH, BAT=$BAT_PATH"

GDBUS_CMD=(gdbus monitor -y -d "$UPower_DBUS_SERVICE")

prev_ac_online=""
prev_batt_level=-1

# run gdbus monitor and process lines
"${GDBUS_CMD[@]}" | while IFS= read -r line || [[ -n "$line" ]]; do
  # AC adapter events
  if [[ "$line" == *"$AC_PATH"* ]]; then
    if [[ "$line" == *"Online': <true>"* ]] && [[ "$prev_ac_online" != "true" ]]; then
      prev_ac_online="true"
      notify_and_play "$EMOJI_CHARGER Charger connected" "AC adapter connected" "$SOUND_AC_CONNECTED"
    elif [[ "$line" == *"Online': <false>"* ]] && [[ "$prev_ac_online" != "false" ]]; then
      prev_ac_online="false"
      notify_and_play "$EMOJI_CHARGER Charger disconnected" "AC adapter disconnected" "$SOUND_AC_DISCONNECTED"
    fi
  fi

  # Battery events
  if [[ "$line" == *"$BAT_PATH"* ]]; then
    perc=$(get_battery_percentage "$BAT_PATH") || true
    [[ -z "$perc" ]] && continue
    # ensure integer
    perc=${perc%.*}

    # ignore tiny fluctuations
    if [[ $prev_batt_level -ne -1 ]]; then
      delta=$(absdiff "$prev_batt_level" "$perc")
      if ((delta < MIN_DELTA)); then
        prev_batt_level=$perc
        continue
      fi
    fi

    if ((perc < THRESHOLD_CRITICAL)); then
      if ((prev_batt_level >= THRESHOLD_CRITICAL || prev_batt_level == -1)); then
        notify_and_play "$EMOJI_BATTERY_CRITICAL Battery critical: ${perc}%" "System may suspend or shut down soon" "$SOUND_CRITICAL"
      fi
    elif ((perc < THRESHOLD_LOW)); then
      if ((prev_batt_level >= THRESHOLD_LOW || prev_batt_level == -1)); then
        notify_and_play "$EMOJI_BATTERY_LOW Low battery: ${perc}%" "Connect the charger" "$SOUND_LOW"
      fi
    elif ((perc > THRESHOLD_HIGH)); then
      if ((prev_batt_level <= THRESHOLD_HIGH || prev_batt_level == -1)); then
        notify_and_play "$EMOJI_BATTERY_OK Battery high: ${perc}%" "You can disconnect the charger" "$SOUND_HIGH"
      fi
    fi

    prev_batt_level=$perc
  fi

done
