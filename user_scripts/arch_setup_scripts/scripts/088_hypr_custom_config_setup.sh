#!/usr/bin/env bash
# ==============================================================================
# Script Name: setup_hypr_overlay.sh
# Description: Initializes the 'edit_here' user configuration overlay for Hyprland.
#              Designed for Arch Linux/Hyprland/UWSM environments.
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. Strict Mode & Configuration
# ------------------------------------------------------------------------------
set -euo pipefail

# --- ANSI Color Codes ---
readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[0;33m'
readonly BLUE=$'\033[0;34m'
readonly RESET=$'\033[0m'

# --- Paths ---
readonly HYPR_DIR="${HOME}/.config/hypr"
readonly SOURCE_DIR="${HYPR_DIR}/source"
readonly EDIT_DIR="${HYPR_DIR}/edit_here"
readonly EDIT_SOURCE_DIR="${EDIT_DIR}/source"
readonly MAIN_CONF="${HYPR_DIR}/hyprland.conf"
readonly NEW_CONF="${EDIT_DIR}/hyprland.conf"

# The path string written into configs (Single quotes to prevent expansion)
readonly INCLUDE_PATH='~/.config/hypr/edit_here/hyprland.conf'

# ------------------------------------------------------------------------------
# 2. Helper Functions
# ------------------------------------------------------------------------------
log_info()    { printf '%s[INFO]%s %s\n' "${BLUE}" "${RESET}" "$1"; }
log_success() { printf '%s[OK]%s   %s\n' "${GREEN}" "${RESET}" "$1"; }
log_warn()    { printf '%s[WARN]%s %s\n' "${YELLOW}" "${RESET}" "$1"; }
log_error()   { printf '%s[ERR]%s  %s\n' "${RED}" "${RESET}" "$1" >&2; }

# ------------------------------------------------------------------------------
# 3. Privilege & Pre-flight Checks
# ------------------------------------------------------------------------------
if [[ ${EUID} -eq 0 ]]; then
    log_error "This script must NOT be run as root."
    log_error "It modifies user configuration files in ${HOME}."
    exit 1
fi

if [[ ! -d ${SOURCE_DIR} ]]; then
    log_error "Source directory not found: ${SOURCE_DIR}"
    log_error "Cannot populate the edit_here directory. Aborting."
    exit 1
fi

if [[ ! -f ${MAIN_CONF} ]]; then
    log_warn "Main Hyprland config not found at ${MAIN_CONF}. Creating empty file."
    mkdir -p -- "${HYPR_DIR}"
    touch -- "${MAIN_CONF}"
fi

# ------------------------------------------------------------------------------
# 4. Main Logic: Create Overlay
# ------------------------------------------------------------------------------
log_info "Initializing Hyprland user configuration overlay..."

if [[ -d ${EDIT_DIR} ]]; then
    log_warn "Directory '${EDIT_DIR}' already exists."
    log_warn "Skipping initialization to protect existing custom configurations."
else
    # 1. Create Directory Structure
    log_info "Creating directory: ${EDIT_DIR}"
    mkdir -p -- "${EDIT_SOURCE_DIR}"

    # 2. Create Empty Template Files
    log_info "Creating empty template files in '${EDIT_SOURCE_DIR}'..."
    
    # Updated list of files to create:
    for file in monitors.conf keybinds.conf appearance.conf autostart.conf \
                plugins.conf window_rules.conf environment_variables.conf; do
        
        target_file="${EDIT_SOURCE_DIR}/${file}"
        
        # Create the file with a specific header description
        cat > "${target_file}" <<EOF
# ==============================================================================
# USER CONFIGURATION: ${file}
# ==============================================================================
# Add your custom settings for ${file%.*} here.
# These will override or add to the defaults found in ~/.config/hypr/source/${file}
# ==============================================================================

EOF
        log_success "Created template: ${file}"
    done

    # 3. Generate the user's overlay config file (The loader)
    log_info "Generating '${NEW_CONF}'..."
    cat > "${NEW_CONF}" <<'EOF'
# ==============================================================================
# USER CONFIGURATION OVERLAY
# ==============================================================================
# This file sources all your custom configuration files.
# Edit the specific files in 'source/' to apply your changes.
# ==============================================================================

source = ~/.config/hypr/edit_here/source/monitors.conf
source = ~/.config/hypr/edit_here/source/keybinds.conf
source = ~/.config/hypr/edit_here/source/appearance.conf
source = ~/.config/hypr/edit_here/source/autostart.conf
source = ~/.config/hypr/edit_here/source/plugins.conf
source = ~/.config/hypr/edit_here/source/window_rules.conf
source = ~/.config/hypr/edit_here/source/environment_variables.conf
EOF
    log_success "Created '${NEW_CONF}'."
fi

# ------------------------------------------------------------------------------
# 5. Modify Main Configuration
# ------------------------------------------------------------------------------
log_info "Updating main configuration at '${MAIN_CONF}'..."

if grep -Fq -- "source = ${INCLUDE_PATH}" "${MAIN_CONF}"; then
    log_success "Main config already sources the overlay. No changes needed."
else
    # Append the source line
    printf '\n# Source User Custom Config Overlay\nsource = %s\n' "${INCLUDE_PATH}" >> "${MAIN_CONF}"
    log_success "Appended source directive to '${MAIN_CONF}'."
fi

# ------------------------------------------------------------------------------
# 6. Completion
# ------------------------------------------------------------------------------
printf '\n'
log_success "Setup complete!"
log_info "You can now edit your custom configs in: ${EDIT_DIR}"
log_info "To apply changes, restart Hyprland or run 'hyprctl reload'."
