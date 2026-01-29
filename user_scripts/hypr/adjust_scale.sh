#!/usr/bin/env bash
# ==============================================================================
# UNIVERSAL HYPRLAND MONITOR SCALER (V15 - PRODUCTION FINAL)
# ==============================================================================
# A robust, atomic, and dependency-minimal script to adjust Hyprland monitor scaling.
#
# Usage: ./hypr-scale.sh [+|-]
# Env:   HYPR_SCALE_MONITOR="DP-1"  (Optional: Target specific monitor)
#        DEBUG=1                    (Optional: Enable verbose logging)
# ==============================================================================

set -euo pipefail
export LC_ALL=C

# --- Immutable Configuration ---
readonly CONFIG_DIR="${HOME}/.config/hypr/edit_here/source"
readonly NOTIFY_TAG="hypr_scale_adjust"
readonly NOTIFY_TIMEOUT=2000
readonly MIN_LOGICAL_WIDTH=640
readonly MIN_LOGICAL_HEIGHT=360

# --- Runtime State ---
DEBUG="${DEBUG:-0}"
TARGET_MONITOR="${HYPR_SCALE_MONITOR:-}"
CONFIG_FILE=""

# --- Logging (All to Stderr) ---
log_err()   { printf '\033[0;31m[ERROR]\033[0m %s\n' "$1" >&2; }
log_warn()  { printf '\033[0;33m[WARN]\033[0m %s\n'  "$1" >&2; }
log_info()  { printf '\033[0;32m[INFO]\033[0m %s\n'  "$1" >&2; }
log_debug() { [[ "${DEBUG}" != "1" ]] || printf '\033[0;34m[DEBUG]\033[0m %s\n' "$1" >&2; }

die() {
    log_err "$1"
    notify-send -u critical "Monitor Scale Failed" "$1" 2>/dev/null || true
    exit 1
}

# --- Pure Bash Utilities ---
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"   # Strip leading whitespace
    s="${s%"${s##*[![:space:]]}"}"   # Strip trailing whitespace
    printf '%s' "$s"
}

# --- Initialization ---
init_config_file() {
    # Check for existing config files in priority order
    if [[ -f "${CONFIG_DIR}/monitors.conf" ]]; then
        CONFIG_FILE="${CONFIG_DIR}/monitors.conf"
        log_debug "Selected config: monitors.conf"
    elif [[ -f "${CONFIG_DIR}/monitor.conf" ]]; then
        CONFIG_FILE="${CONFIG_DIR}/monitor.conf"
        log_debug "Selected config: monitor.conf"
    else
        # Default to creating monitor.conf
        CONFIG_FILE="${CONFIG_DIR}/monitor.conf"
        log_debug "Creating new config: monitor.conf"
        mkdir -p -- "${CONFIG_DIR}"
        : > "$CONFIG_FILE"
    fi
}

check_dependencies() {
    local missing=() cmd
    for cmd in hyprctl jq awk notify-send; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    ((${#missing[@]} == 0)) || die "Missing dependencies: ${missing[*]}"
}

# --- Notification Helper ---
notify_user() {
    local scale="$1" monitor="$2" extra="${3:-}"
    log_info "Monitor: ${monitor} | Scale: ${scale}${extra:+ | ${extra}}"
    
    # Use printf formatting for cleaner notify-send payloads
    local body="Monitor: ${monitor}"
    [[ -n "$extra" ]] && body+=$'\n'"${extra}"
    
    notify-send \
        -h "string:x-canonical-private-synchronous:${NOTIFY_TAG}" \
        -u low -t "$NOTIFY_TIMEOUT" \
        "Display Scale: ${scale}" \
        "$body" 2>/dev/null || true
}

# --- Scale Calculation Engine ---
# Inputs: current_scale direction phys_width phys_height
# Outputs: new_scale logical_w logical_h changed
compute_next_scale() {
    local current="$1" direction="$2" phys_w="$3" phys_h="$4"

    # We use awk for float math. Critical: Iterate numerically, not by 'in array'.
    awk -v cur="$current" -v dir="$direction" \
        -v w="$phys_w" -v h="$phys_h" \
        -v min_w="$MIN_LOGICAL_WIDTH" -v min_h="$MIN_LOGICAL_HEIGHT" '
    BEGIN {
        # Hyprland "Golden List" + Common High-DPI scales
        # Sorted ascending is required for the logic below.
        n = split("0.5 0.6 0.75 0.8 0.9 1.0 1.0625 1.1 1.125 1.15 1.2 1.25 1.33 1.4 1.5 1.6 1.67 1.75 1.8 1.88 2.0 2.25 2.4 2.5 2.67 2.8 3.0", raw)
        count = 0

        # Filter: Verify logical resolution and integer alignment
        for (i = 1; i <= n; i++) {
            s = raw[i] + 0
            
            # Check 1: Minimum usable logical resolution
            lw = w / s; lh = h / s
            if (lw < min_w || lh < min_h) continue
            
            # Check 2: Integer Alignment (Prevent fuzzy rendering)
            frac = lw - int(lw)
            if (frac > 0.5) frac = 1.0 - frac
            if (frac > 0.05) continue
            
            valid[++count] = s
        }
        
        # Fallback to 1.0 if strict filtering removed everything
        if (count == 0) { valid[1] = 1.0; count = 1 }

        # Find closest existing scale index
        best = 1; mindiff = 1e9
        for (i = 1; i <= count; i++) {
            d = cur - valid[i]
            if (d < 0) d = -d
            if (d < mindiff) { mindiff = d; best = i }
        }

        # Calculate target index
        target = (dir == "+") ? best + 1 : best - 1
        
        # Clamp bounds
        if (target < 1) target = 1
        if (target > count) target = count

        ns = valid[target]
        
        # Detect change (float epsilon comparison)
        changed = (((ns - cur)^2) > 0.000001) ? 1 : 0

        # Format output: Strip trailing zeros (e.g. 1.50 -> 1.5)
        fmt = sprintf("%.6f", ns)
        sub(/0+$/, "", fmt)
        sub(/\.$/, "", fmt)

        printf "%s %d %d %d\n", fmt, int(w/ns + 0.5), int(h/ns + 0.5), changed
    }'
}

# --- Config Manager ---
update_config_file() {
    local monitor="$1" new_scale="$2"
    local tmpfile found=0

    # Atomic write pattern
    tmpfile=$(mktemp) || die "Failed to create temp file"
    trap 'rm -f -- "$tmpfile"' EXIT

    log_debug "Updating config: ${monitor} -> ${new_scale}"

    # Read config line-by-line using Bash builtins
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Check if line starts with 'monitor ='
        if [[ "$line" =~ ^[[:space:]]*monitor[[:space:]]*= ]]; then
            
            # Extract content after '='
            local content="${line#*=}"
            
            # SAFETY: Strip inline comments (#...) before parsing fields
            content="${content%%#*}"
            content="$(trim "$content")"

            # Parse fields by comma
            local -a fields
            IFS=',' read -ra fields <<< "$content"
            
            # Monitor name is the first field
            local mon_name
            mon_name="$(trim "${fields[0]}")"

            if [[ "$mon_name" == "$monitor" ]]; then
                log_debug "Found existing entry for: ${monitor}"
                found=1
                
                # Reconstruct line: monitor = Name, Res, Pos, SCALE, Extras...
                local new_line="monitor = ${mon_name}"
                
                # Append Resolution (default to preferred if missing)
                new_line+=", $(trim "${fields[1]:-preferred}")"
                
                # Append Position (default to auto if missing)
                new_line+=", $(trim "${fields[2]:-auto}")"
                
                # Append NEW Scale
                new_line+=", ${new_scale}"

                # Append any remaining fields (mirror, bitdepth, vrr, etc.)
                local i
                for ((i = 4; i < ${#fields[@]}; i++)); do
                    new_line+=", $(trim "${fields[i]}")"
                done
                
                # Write to temp file
                printf '%s\n' "$new_line" >> "$tmpfile"
                continue
            fi
        fi

        # Pass through unrelated lines unchanged
        printf '%s\n' "$line" >> "$tmpfile"
    done < "$CONFIG_FILE"

    # If monitor not found, append new entry
    if ((found == 0)); then
        log_info "Appending new entry for: ${monitor}"
        printf 'monitor = %s, preferred, auto, %s\n' "$monitor" "$new_scale" >> "$tmpfile"
    fi

    # Atomic Move
    mv -f -- "$tmpfile" "$CONFIG_FILE"
    trap - EXIT
}

# --- Format Refresh Rate Helper ---
format_refresh() {
    awk -v r="$1" 'BEGIN { fmt = sprintf("%.2f", r); sub(/\.00$/, "", fmt); print fmt }'
}

# --- Main Execution ---
main() {
    check_dependencies
    init_config_file

    if [[ $# -ne 1 ]] || [[ "$1" != "+" && "$1" != "-" ]]; then
        printf 'Usage: %s [+|-]\n' "${0##*/}" >&2
        exit 1
    fi
    local direction="$1"

    # 1. Get Monitor State (JSON)
    local monitors_json
    monitors_json=$(hyprctl -j monitors) || die "Cannot connect to Hyprland"

    # 2. Resolve Target Monitor
    local monitor="${TARGET_MONITOR}"
    [[ -n "$monitor" ]] || monitor=$(jq -r '.[] | select(.focused) | .name // empty' <<< "$monitors_json")
    [[ -n "$monitor" ]] || monitor=$(jq -r '.[0].name // empty' <<< "$monitors_json")
    [[ -n "$monitor" ]] || die "No active monitors found"

    log_info "Target: ${monitor}"

    # 3. Extract Properties
    local props
    props=$(jq -r --arg m "$monitor" \
        '.[] | select(.name == $m) | "\(.width) \(.height) \(.scale) \(.refreshRate) \(.x) \(.y)"' \
        <<< "$monitors_json")
    [[ -n "$props" ]] || die "Monitor '${monitor}' details not found"

    local width height current_scale refresh pos_x pos_y
    read -r width height current_scale refresh pos_x pos_y <<< "$props"

    log_debug "State: ${width}x${height} @ ${current_scale}"

    # 4. Compute New Scale
    local scale_output new_scale logic_w logic_h changed
    scale_output=$(compute_next_scale "$current_scale" "$direction" "$width" "$height")
    read -r new_scale logic_w logic_h changed <<< "$scale_output"

    # 5. Check Limits
    if ((changed == 0)); then
        log_warn "Limit reached: ${new_scale}"
        notify_user "$new_scale" "$monitor" "(Limit Reached)"
        exit 0
    fi

    # 6. Persist Config (Safe Update)
    update_config_file "$monitor" "$new_scale"

    # 7. Apply Runtime (Live)
    local refresh_fmt rule
    refresh_fmt=$(format_refresh "$refresh")
    rule="${monitor},${width}x${height}@${refresh_fmt},${pos_x}x${pos_y},${new_scale}"

    log_info "Applying: ${rule}"

    if hyprctl keyword monitor "$rule" &>/dev/null; then
        # Wait for IPC propagation
        sleep 0.15

        # Verify application
        local actual_scale
        actual_scale=$(hyprctl -j monitors | jq -r --arg m "$monitor" '.[] | select(.name == $m) | .scale')

        # Check for Hyprland internal adjustment
        if awk -v a="$actual_scale" -v b="$new_scale" 'BEGIN { exit !(((a - b)^2) > 0.000001) }'; then
            log_warn "Hyprland auto-adjusted: ${new_scale} -> ${actual_scale}"
            notify_user "Adjusted" "$monitor" "Requested ${new_scale}, got ${actual_scale}"
            # Sync config to reality
            update_config_file "$monitor" "$actual_scale"
        else
            notify_user "$new_scale" "$monitor" "Logical: ${logic_w}x${logic_h}"
        fi
    else
        die "Hyprland rejected rule: ${rule}"
    fi
}

main "$@"
