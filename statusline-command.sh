#!/bin/bash
# SPDX-License-Identifier: 0BSD
# Claude Code status line.
# Line 1: model + effort, folder icon + working dir (colored like the ~/.bashrc prompt), git branch.
# Line 2: context-window usage bar, tokens in context with the session cost, elapsed time.
# Lines 3+: Claude.ai subscription limits (5h / 7d) with the local time each window resets, only when the
#           API reports them, followed by one line per model-scoped weekly window (e.g. Fable) if the
#           payload carries `rate_limits.model_scoped`.

input=$(cat)

MODEL=$(echo "$input" | jq -r '.model.display_name // empty')
EFFORT=$(echo "$input" | jq -r '.effort.level // empty')
COST=$(echo "$input" | jq -r '.cost.total_cost_usd // 0')
PCT=$(echo "$input" | jq -r '.context_window.used_percentage // 0' | cut -d. -f1)
TOKENS=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0' | cut -d. -f1)
DURATION_MS=$(echo "$input" | jq -r '.cost.total_duration_ms // 0')
FIVE_H=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty' | cut -d. -f1)
FIVE_H_RESET=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
SEVEN_D=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty' | cut -d. -f1)
SEVEN_D_RESET=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
# Per-model weekly windows, one TAB-separated line each: display_name, percent, resets_at.
# Not in the documented status-line payload yet (CLI 2.1.263 only sends it on the SDK `get_usage` request,
# where it is `display_name` + `utilization` 0-100 + ISO 8601 `resets_at`). Both field spellings and both
# timestamp forms are accepted so the block lights up unchanged once the field arrives.
MODEL_SCOPED=$(echo "$input" | jq -r '(.rate_limits.model_scoped // [])[]
    | select(.display_name != null)
    | [.display_name, ((.used_percentage // .utilization // 0) | floor), (.resets_at // "")] | @tsv' 2>/dev/null)

cwd=$(echo "$input" | jq -r '.workspace.current_dir // empty')
[ -z "$cwd" ] && cwd=$PWD

# Replace $HOME with ~ to mirror bash's \w behavior
dir="$cwd"
if [ -n "$HOME" ] && [ "${dir#"$HOME"}" != "$dir" ]; then
    dir="~${dir#"$HOME"}"
fi

chroot_prefix=""
if [ -r /etc/debian_chroot ]; then
    chroot_prefix="($(cat /etc/debian_chroot)) "
fi

BAR_WIDTH=20

CYAN='\033[36m'; GREEN='\033[32m'; YELLOW='\033[33m'; RED='\033[31m'; RESET='\033[0m'
# "Money" colour for cost and effort level: the amber Claude Code's default dark theme uses for its own
# mode indicator (theme colour `warning`, rgb(255,193,7)), so all three match. Falls back to ANSI yellow
# on terminals without truecolor support.
case "$COLORTERM" in
    truecolor|24bit) MONEY='\033[38;2;255;193;7m' ;;
    *) MONEY="$YELLOW" ;;
esac

# to_epoch <unix_epoch_seconds | ISO 8601> -> unix epoch seconds, empty if unparseable.
# An ISO timestamp is handed over whole, so a trailing UTC offset still counts. GNU date
# parses it directly; BSD date (macOS) has no -d and its -j -f wants no fractional seconds
# and no colon in the offset, so the string is normalized before that second attempt.
to_epoch() {
    local ts=$1 norm
    [ -z "$ts" ] && return 0
    case "$ts" in
        *[!0-9.]*) ;;
        *) printf '%s' "${ts%%.*}"; return 0 ;;
    esac
    date -d "$ts" +%s 2>/dev/null && return 0
    norm=$(printf '%s' "$ts" | sed -E 's/\.[0-9]+//; s/Z$/+0000/; s/([+-][0-9]{2}):([0-9]{2})$/\1\2/')
    date -j -f '%Y-%m-%dT%H:%M:%S%z' "$norm" +%s 2>/dev/null
}

# fmt_local <unix_epoch_seconds> <strftime format> -> local time, on GNU date and on BSD date
fmt_local() {
    date -d "@$1" +"$2" 2>/dev/null || date -r "$1" +"$2" 2>/dev/null
}

# reset_at <unix_epoch_seconds | ISO 8601> -> the reset as local wall-clock time, a TAB, and the time left:
# "14:30<TAB>in 2h 14m" when it falls on today, "Thu 18.09. 14:30<TAB>in 2d 2h 14m" on any later day,
# "now<TAB>" once the window has elapsed. Leading zero units are dropped: "in 14m", "in 2h 14m".
# Weekday and day/month follow the terminal's LC_TIME, so this reads in the user's own locale.
reset_at() {
    local target now left d h m at
    target=$(to_epoch "$1")
    [ -z "$target" ] && return 0
    now=$(date +%s)
    [ "$target" -le "$now" ] && { printf 'now\t'; return 0; }

    if [ "$(fmt_local "$target" %F)" = "$(fmt_local "$now" %F)" ]; then
        at=$(fmt_local "$target" '%H:%M')
    else
        at=$(fmt_local "$target" '%a %d.%m. %H:%M')
    fi
    left=$((target - now)); d=$((left / 86400)); h=$(((left % 86400) / 3600)); m=$(((left % 3600) / 60))
    if [ "$d" -gt 0 ]; then
        printf '%s\tin %dd %dh %dm' "$at" "$d" "$h" "$m"
    elif [ "$h" -gt 0 ]; then
        printf '%s\tin %dh %dm' "$at" "$h" "$m"
    else
        printf '%s\tin %dm' "$at" "$m"
    fi
}

# fmt_tokens <count> -> "842" / "67.5k" / "1.24M" — same basis as used_percentage,
# i.e. input + cache creation + cache read, without output tokens
fmt_tokens() {
    local n=${1:-0}
    if [ "$n" -ge 1000000 ]; then
        printf '%d.%02dM' $((n / 1000000)) $(((n % 1000000) / 10000))
    elif [ "$n" -ge 1000 ]; then
        printf '%d.%dk' $((n / 1000)) $(((n % 1000) / 100))
    else
        printf '%d' "$n"
    fi
}

# render_bar <label> <percent> [resets_at] -> "Label  ██████░░░░░░░░░░░░░░ 30% | ⏰ Resets 14:30 (in 2h 14m)"
# The reset time is cyan like the model name, the duration inside the bracket amber like the cost.
render_bar() {
    local label=$1 pct=$2 reset=$3 color filled empty fill pad at left
    [ -z "$pct" ] && pct=0
    [ "$pct" -lt 0 ] 2>/dev/null && pct=0

    if [ "$pct" -ge 90 ]; then color="$RED"
    elif [ "$pct" -ge 70 ]; then color="$YELLOW"
    else color="$GREEN"; fi

    filled=$((pct * BAR_WIDTH / 100)); [ "$filled" -gt "$BAR_WIDTH" ] && filled=$BAR_WIDTH
    empty=$((BAR_WIDTH - filled))
    printf -v fill "%${filled}s"; printf -v pad "%${empty}s"

    printf "%-7s %b%s%s%b %3s%%" "$label" "$color" "${fill// /█}" "${pad// /░}" "$RESET" "$pct"
    if [ -n "$reset" ]; then
        IFS=$'\t' read -r at left <<< "$(reset_at "$reset")"
        printf " | ⏰ Resets %b%s%b" "$CYAN" "$at" "$RESET"
        [ -n "$left" ] && printf " (in %b%s%b)" "$MONEY" "${left#in }" "$RESET"
    fi
}

MINS=$((DURATION_MS / 60000)); SECS=$(((DURATION_MS % 60000) / 1000))

BRANCH=""
git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1 &&
    BRANCH=" | 🌿 $(git -C "$cwd" branch --show-current 2>/dev/null)"

MODEL_FMT=""
if [ -n "$MODEL" ]; then
    # .effort.level is absent on models without effort support and on CLI < 2.1
    # The effort level shares the money colour with the cost on line 2: higher effort costs more.
    EFFORT_FMT=""
    [ -n "$EFFORT" ] && EFFORT_FMT="${RESET} · ${MONEY}$EFFORT${CYAN}"
    MODEL_FMT="${CYAN}[$MODEL$EFFORT_FMT]${RESET} "
fi

printf "%b%s📂 \033[01;34m%s\033[00m%b\n" "$MODEL_FMT" "$chroot_prefix" "$dir" "$BRANCH"

COST_FMT=$(LC_ALL=C printf '$%.2f' "$COST" 2>/dev/null || echo '$0.00')
# The token count is cyan like the reset time on the limit lines, the cost amber like their countdown.
printf "%b | 🪙 Tokens %b%s%b (%b%s%b) | ⏱️ %sm %ss\n" "$(render_bar Context "$PCT")" "$CYAN" "$(fmt_tokens "$TOKENS")" "$RESET" "$MONEY" "$COST_FMT" "$RESET" "$MINS" "$SECS"

# Subscription limits: only present for Claude.ai subscribers, per window
[ -n "$FIVE_H" ]  && printf "%b\n" "$(render_bar '5h' "$FIVE_H" "$FIVE_H_RESET")"
[ -n "$SEVEN_D" ] && printf "%b\n" "$(render_bar '7d' "$SEVEN_D" "$SEVEN_D_RESET")"
# Model-scoped weekly windows (e.g. Fable), labelled with the server-supplied model name
if [ -n "$MODEL_SCOPED" ]; then
    while IFS=$'\t' read -r ms_name ms_pct ms_reset; do
        [ -z "$ms_name" ] && continue
        printf "%b\n" "$(render_bar "$ms_name" "$ms_pct" "$ms_reset")"
    done <<< "$MODEL_SCOPED"
fi

exit 0
