#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Dusky Input (v1.1 - Production / Symlink-Safe)
# -----------------------------------------------------------------------------
# Target: Arch Linux / Hyprland / UWSM
# Description: Tabbed TUI to modify input.conf.
# -----------------------------------------------------------------------------

set -uo pipefail

# --- Configuration ---
readonly VERSION="1.1"
readonly CONFIG_FILE="${HOME}/.config/hypr/source/input.conf"
declare -ri MAX_DISPLAY_ROWS=14
# 20ms timeout: Safe for SSH/fast typing, prevents split escape codes
readonly ESC_READ_TIMEOUT=0.02

# --- ANSI Constants ---
readonly C_RESET=$'\033[0m'
readonly C_CYAN=$'\033[1;36m'
readonly C_GREEN=$'\033[1;32m'
readonly C_MAGENTA=$'\033[1;35m'
readonly C_RED=$'\033[1;31m'
readonly C_WHITE=$'\033[1;37m'
readonly C_GREY=$'\033[1;30m'
readonly C_INVERSE=$'\033[7m'
readonly CLR_EOL=$'\033[K'
readonly CLR_EOS=$'\033[J'
readonly CURSOR_HOME=$'\033[H'
readonly CURSOR_HIDE=$'\033[?25l'
readonly CURSOR_SHOW=$'\033[?25h'
# SGR Mouse Mode (1006) + Button Event (1002)
readonly MOUSE_ON=$'\033[?1000h\033[?1002h\033[?1006h'
readonly MOUSE_OFF=$'\033[?1000l\033[?1002l\033[?1006l'

# --- State ---
declare -i SELECTED_ROW=0
declare -i CURRENT_TAB=0
readonly -a TABS=("Keyboard" "Mouse" "Touchpad" "Cursor" "Gestures")
declare -ri TAB_COUNT=${#TABS[@]}

# Mouse Click Zones (Calculated during draw)
declare -a TAB_ZONES=()

# --- Data Structures ---
declare -A ITEM_MAP      # label -> "key|type|block|min|max|step"
declare -A VALUE_CACHE   # label -> cached value
declare -a TAB_ITEMS_0=() TAB_ITEMS_1=() TAB_ITEMS_2=() TAB_ITEMS_3=() TAB_ITEMS_4=()

# --- Registration ---
register() {
    local -i tab_idx=$1
    local label=$2 config=$3
    
    # Safety bounds check
    (( tab_idx < 0 || tab_idx >= TAB_COUNT )) && return 1

    ITEM_MAP["$label"]=$config
    local -n tab_ref="TAB_ITEMS_${tab_idx}"
    tab_ref+=("$label")
}

# --- DEFINITIONS ---

# Tab 0: Keyboard (Block: 'input')
register 0 "Layout"             "kb_layout|cycle|input|us,uk,de,fr,es|us|"
register 0 "Numlock Default"    "numlock_by_default|bool|input|||"
register 0 "Repeat Rate"        "repeat_rate|int|input|10|100|5"
register 0 "Repeat Delay"       "repeat_delay|int|input|100|1000|50"
register 0 "Resolve Binds Sym"  "resolve_binds_by_sym|bool|input|||"

# Tab 1: Mouse (Block: 'input')
register 1 "Sensitivity"        "sensitivity|float|input|-1.0|1.0|0.1"
register 1 "Accel Profile"      "accel_profile|cycle|input|flat,adaptive,custom|adaptive|"
register 1 "Force No Accel"     "force_no_accel|bool|input|||"
register 1 "Left Handed"        "left_handed|bool|input|||"
register 1 "Follow Mouse"       "follow_mouse|int|input|0|3|1"
register 1 "Mouse Refocus"      "mouse_refocus|bool|input|||"
# FIX: Renamed label to avoid collision with Touchpad
register 1 "Mouse Nat Scroll"   "natural_scroll|bool|input|||"
register 1 "Scroll Method"      "scroll_method|cycle|input|2fg,edge,on_button_down,no_scroll|2fg|"

# Tab 2: Touchpad (Block: 'touchpad')
# FIX: Renamed label to avoid collision with Mouse
register 2 "TP Nat Scroll"      "natural_scroll|bool|touchpad|||"
register 2 "Tap to Click"       "tap-to-click|bool|touchpad|||"
register 2 "Disable While Typing" "disable_while_typing|bool|touchpad|||"
register 2 "Clickfinger Behav"  "clickfinger_behavior|bool|touchpad|||"
register 2 "Drag Lock"          "drag_lock|bool|touchpad|||"

# Tab 3: Cursor (Block: 'cursor')
register 3 "No HW Cursors"      "no_hardware_cursors|int|cursor|0|2|1"
register 3 "Use CPU Buffer"     "use_cpu_buffer|int|cursor|0|2|1"
register 3 "Hide On Key"        "hide_on_key_press|bool|cursor|||"
register 3 "Inactive Timeout"   "inactive_timeout|int|cursor|0|60|5"
register 3 "Warp On Change"     "warp_on_change_workspace|int|cursor|0|2|1"
register 3 "No Break VRR"       "no_break_fs_vrr|int|cursor|0|2|1"
register 3 "Zoom Factor"        "zoom_factor|float|cursor|1.0|5.0|0.1"

# Tab 4: Gestures (Block: 'gestures')
register 4 "Swipe Distance"     "workspace_swipe_distance|int|gestures|100|1000|50"
register 4 "Swipe Cancel Ratio" "workspace_swipe_cancel_ratio|float|gestures|0.0|1.0|0.1"
register 4 "Swipe Invert"       "workspace_swipe_invert|bool|gestures|||"
register 4 "Swipe Create New"   "workspace_swipe_create_new|bool|gestures|||"
register 4 "Swipe Forever"      "workspace_swipe_forever|bool|gestures|||"

# --- DEFAULTS ---
# Updated keys to match the new unique labels above
declare -A DEFAULTS=(
    # Keyboard
    ["Layout"]="us"
    ["Numlock Default"]="true"
    ["Repeat Rate"]="35"
    ["Repeat Delay"]="250"
    ["Resolve Binds Sym"]="false"
    # Mouse
    ["Sensitivity"]="0"
    ["Accel Profile"]="adaptive"
    ["Force No Accel"]="false"
    ["Left Handed"]="true"
    ["Follow Mouse"]="1"
    ["Mouse Refocus"]="true"
    ["Mouse Nat Scroll"]="false" # Renamed
    ["Scroll Method"]="2fg"
    # Touchpad
    ["TP Nat Scroll"]="true"     # Renamed
    ["Tap to Click"]="true"
    ["Disable While Typing"]="true"
    ["Clickfinger Behav"]="false"
    ["Drag Lock"]="false"
    # Cursor
    ["No HW Cursors"]="2"
    ["Use CPU Buffer"]="2"
    ["Hide On Key"]="false"
    ["Inactive Timeout"]="0"
    ["Warp On Change"]="0"
    ["No Break VRR"]="2"
    ["Zoom Factor"]="1.0"
    # Gestures
    ["Swipe Distance"]="300"
    ["Swipe Cancel Ratio"]="0.5"
    ["Swipe Invert"]="true"
    ["Swipe Create New"]="true"
    ["Swipe Forever"]="false"
)

# --- Helpers ---
log_err() { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; }

cleanup() {
    printf '%s%s%s' "$MOUSE_OFF" "$CURSOR_SHOW" "$C_RESET"
    clear
}

# Required for sed to handle special chars safely
escape_sed_replacement() {
    local s=$1
    s=${s//\\/\\\\}
    s=${s//&/\\&}
    s=${s//\//\\/}
    printf '%s' "$s"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Core Logic ---

# Returns the exact LINE NUMBER of the key.
# Safety: Respects block nesting.
get_line_of_key() {
    local key=$1 block=$2
    
    awk -v key="$key" -v target_block="$block" '
        BEGIN { 
            # block_depth: -1 = outside, 0 = inside target, >0 = inside nested block of target
            block_depth = -1 
        }
        /^[[:space:]]*#/ { next }
        /{/ {
            if (block_depth == -1) {
                if (match($0, "^[[:space:]]*" target_block "[[:space:]]*\\{")) block_depth = 0
            } else {
                block_depth++
            }
        }
        /}/ {
            if (block_depth > -1) {
                block_depth--
                if (block_depth < 0) block_depth = -1
            }
        }
        /=/ {
            if (block_depth == 0) {
                if (match($0, "^[[:space:]]*" key "[[:space:]]*=")) {
                    print NR
                    exit
                }
            }
        }
    ' "$CONFIG_FILE"
}

get_value_from_file() {
    local key=$1 block=$2
    local line_num
    
    line_num=$(get_line_of_key "$key" "$block")
    [[ -z $line_num ]] && return

    # Optimized extraction: find line, print field 2, trim
    awk -F= -v ln="$line_num" '
        NR == ln {
            val = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            sub(/[[:space:]]*#.*$/, "", val)
            print val
            exit
        }
    ' "$CONFIG_FILE"
}

write_value_to_file() {
    local key=$1 new_val=$2 block=$3
    local safe_val line_num
    safe_val=$(escape_sed_replacement "$new_val")
    
    line_num=$(get_line_of_key "$key" "$block")
    
    if [[ -n $line_num ]]; then
        # CRITICAL: We use `sed --follow-symlinks` instead of `mv` to preserve
        # the integrity of dotfile symlinks managed by stow/yadm.
        sed --follow-symlinks -i \
            "${line_num}s|^\([[:space:]]*${key}[[:space:]]*=[[:space:]]*\)[^#[:space:]]*|\1${safe_val}|" \
            "$CONFIG_FILE"
        return 0
    else
        return 1
    fi
}

load_tab_values() {
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item key type block val

    for item in "${items_ref[@]}"; do
        IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP[$item]}"
        val=$(get_value_from_file "$key" "$block")
        VALUE_CACHE["$item"]=${val:-unset}
    done
}

modify_value() {
    local label=$1
    local -i direction=$2
    local key type block min max step current new_val

    IFS='|' read -r key type block min max step <<< "${ITEM_MAP[$label]}"
    current=${VALUE_CACHE[$label]:-}
    [[ $current == "unset" ]] && current=""

    case $type in
        int)
            [[ ! $current =~ ^-?[0-9]+$ ]] && current=${min:-0}
            local -i int_step=${step:-1} int_val=$current
            (( int_val += direction * int_step )) || :
            [[ -n $min ]] && (( int_val < min )) && int_val=$min
            [[ -n $max ]] && (( int_val > max )) && int_val=$max
            new_val=$int_val
            ;;
        float)
            [[ ! $current =~ ^-?[0-9]*\.?[0-9]+$ ]] && current=${min:-0.0}
            new_val=$(awk -v c="$current" -v dir="$direction" -v s="${step:-0.1}" \
                          -v mn="$min" -v mx="$max" '
                BEGIN {
                    val = c + (dir * s)
                    if (mn != "" && val < mn) val = mn
                    if (mx != "" && val > mx) val = mx
                    printf "%.4g", val
                }
            ')
            ;;
        bool)
            [[ $current == "true" ]] && new_val="false" || new_val="true"
            ;;
        cycle)
            local options_str=$min
            IFS=',' read -r -a opts <<< "$options_str"
            local -i idx=0 found=0 count=${#opts[@]}
            
            for (( i=0; i<count; i++ )); do
                [[ "${opts[i]}" == "$current" ]] && { idx=$i; found=1; break; }
            done
            
            [[ $found -eq 0 ]] && idx=0
            (( idx += direction )) || :
            (( idx < 0 )) && idx=$(( count - 1 ))
            (( idx >= count )) && idx=0
            new_val=${opts[idx]}
            ;;
        *) return 0 ;;
    esac

    if write_value_to_file "$key" "$new_val" "$block"; then
        VALUE_CACHE["$label"]=$new_val
    fi
}

set_absolute_value() {
    local label=$1 new_val=$2
    local key type block
    IFS='|' read -r key type block _ _ _ <<< "${ITEM_MAP[$label]}"
    if write_value_to_file "$key" "$new_val" "$block"; then
        VALUE_CACHE["$label"]=$new_val
    fi
}

reset_defaults() {
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local item def_val
    
    for item in "${items_ref[@]}"; do
        def_val=${DEFAULTS[$item]:-}
        [[ -n $def_val ]] && set_absolute_value "$item" "$def_val"
    done
}

# --- UI Rendering ---

draw_ui() {
    local buf=""
    local -i i current_col=3
    
    buf+="${CURSOR_HOME}"
    buf+="${C_MAGENTA}┌────────────────────────────────────────────────────────────────────────────┐${C_RESET}"$'\n'
    buf+="${C_MAGENTA}│$(printf '%*s' 30 '')${C_WHITE}Dusky Input ${C_CYAN}v${VERSION}${C_MAGENTA}$(printf '%*s' 30 '')│${C_RESET}"$'\n'
    
    local tab_line="${C_MAGENTA}│ "
    TAB_ZONES=()
    
    for (( i = 0; i < TAB_COUNT; i++ )); do
        local name=${TABS[i]}
        local -i len=${#name}
        local -i zone_start=$current_col
        
        if (( i == CURRENT_TAB )); then
            tab_line+="${C_CYAN}${C_INVERSE} ${name} ${C_RESET}${C_MAGENTA}│ "
        else
            tab_line+="${C_GREY} ${name} ${C_MAGENTA}│ "
        fi
        
        TAB_ZONES+=("${zone_start}:$(( zone_start + len + 1 ))")
        (( current_col += len + 4 ))
    done
    
    local -i tab_line_len=$(( current_col - 1 ))
    local -i pad_needed=$(( 77 - tab_line_len ))
    
    (( pad_needed > 0 )) && tab_line+=$(printf '%*s' "$pad_needed" '')
    tab_line+="${C_MAGENTA}│${C_RESET}"
    
    buf+="${tab_line}"$'\n'
    buf+="${C_MAGENTA}└────────────────────────────────────────────────────────────────────────────┘${C_RESET}"$'\n'

    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#items_ref[@]}
    local item val display

    (( SELECTED_ROW >= count )) && SELECTED_ROW=$(( count - 1 ))
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=0

    for (( i = 0; i < count; i++ )); do
        item=${items_ref[i]}
        val=${VALUE_CACHE[$item]:-unset}

        case $val in
            true)         display="${C_GREEN}ON${C_RESET}" ;;
            false)        display="${C_RED}OFF${C_RESET}" ;;
            unset)        display="${C_RED}unset${C_RESET}" ;;
            *)            display="${C_WHITE}${val}${C_RESET}" ;;
        esac
        
        if (( i == SELECTED_ROW )); then
            buf+="${C_CYAN} ➤ ${C_INVERSE}"
            buf+=$(printf '%-32s' "$item")
            buf+="${C_RESET} : ${display}${CLR_EOL}"$'\n'
        else
            buf+="   "
            buf+=$(printf ' %-32s' "$item")
            buf+=" : ${display}${CLR_EOL}"$'\n'
        fi
    done

    for (( i = count; i < MAX_DISPLAY_ROWS; i++ )); do
        buf+="${CLR_EOL}"$'\n'
    done

    buf+=$'\n'"${C_CYAN} [Tab] Category  [r] Reset  [←/→ h/l] Adjust  [↑/↓ j/k] Nav  [q] Quit${C_RESET}"$'\n'
    buf+="${C_CYAN} File: ${C_WHITE}${CONFIG_FILE}${C_RESET}${CLR_EOL}${CLR_EOS}"
    
    printf '%s' "$buf"
}

# --- Input Handling ---

navigate() {
    local -i dir=$1
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    local -i count=${#items_ref[@]}
    (( SELECTED_ROW += dir )) || :
    (( SELECTED_ROW < 0 )) && SELECTED_ROW=$(( count - 1 ))
    (( SELECTED_ROW >= count )) && SELECTED_ROW=0
}

adjust() {
    local -i dir=$1
    local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
    [[ ${#items_ref[@]} -eq 0 ]] && return 0
    modify_value "${items_ref[SELECTED_ROW]}" "$dir"
}

switch_tab() {
    local -i dir=${1:-1}
    (( CURRENT_TAB += dir )) || :
    (( CURRENT_TAB >= TAB_COUNT )) && CURRENT_TAB=0
    (( CURRENT_TAB < 0 )) && CURRENT_TAB=$(( TAB_COUNT - 1 ))
    SELECTED_ROW=0
    load_tab_values
    clear
}

set_tab() {
    local -i idx=$1
    if (( idx != CURRENT_TAB && idx >= 0 && idx < TAB_COUNT )); then
        CURRENT_TAB=$idx
        SELECTED_ROW=0
        load_tab_values
        clear
    fi
}

handle_mouse() {
    local input=$1
    local -i button x y i
    local type zone start end
    
    if [[ $input =~ ^\[\<([0-9]+)\;([0-9]+)\;([0-9]+)([Mm])$ ]]; then
        button=${BASH_REMATCH[1]}
        x=${BASH_REMATCH[2]}
        y=${BASH_REMATCH[3]}
        type=${BASH_REMATCH[4]}
        
        [[ $type != "M" ]] && return 0

        if (( y == 3 )); then
            for (( i = 0; i < TAB_COUNT; i++ )); do
                zone=${TAB_ZONES[i]}
                start=${zone%%:*}
                end=${zone##*:}
                if (( x >= start && x <= end )); then
                    set_tab "$i"
                    return 0
                fi
            done
        fi
        
        local -i item_start_y=5
        local -n items_ref="TAB_ITEMS_${CURRENT_TAB}"
        local -i count=${#items_ref[@]}
        
        if (( y >= item_start_y && y < item_start_y + count )); then
            SELECTED_ROW=$(( y - item_start_y ))
            if (( x > 40 )); then
                (( button == 0 )) && adjust 1 || adjust -1
            fi
        fi
    fi
}

# --- Main ---

main() {
    [[ ! -f $CONFIG_FILE ]] && { log_err "Config not found: $CONFIG_FILE"; exit 1; }
    command -v awk &>/dev/null || { log_err "Required: awk"; exit 1; }
    command -v sed &>/dev/null || { log_err "Required: sed"; exit 1; }

    printf '%s%s' "$MOUSE_ON" "$CURSOR_HIDE"
    load_tab_values
    clear

    local key seq char
    while true; do
        draw_ui
        
        IFS= read -rsn1 key || :
        
        if [[ $key == $'\x1b' ]]; then
            seq=""
            # Using increased timeout (0.02s) to capture escape sequences reliably
            while IFS= read -rsn1 -t "$ESC_READ_TIMEOUT" char; do
                seq+="$char"
            done
            
            case $seq in
                '[Z')               switch_tab -1 ;;
                '[A'|'OA')          navigate -1 ;;
                '[B'|'OB')          navigate 1 ;;
                '[C'|'OC')          adjust 1 ;;
                '[D'|'OD')          adjust -1 ;;
                '['*'<'*)           handle_mouse "$seq" ;;
            esac
        else
            case $key in
                k|K)            navigate -1 ;;
                j|J)            navigate 1 ;;
                l|L)            adjust 1 ;;
                h|H)            adjust -1 ;;
                $'\t')          switch_tab 1 ;;
                r|R)            reset_defaults ;;
                q|Q|$'\x03')    break ;;
            esac
        fi
    done
}

main
