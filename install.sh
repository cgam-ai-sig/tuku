#!/usr/bin/env bash
set -euo pipefail

# install.sh — system-wide installer for tuku
# Copies scripts to /usr/local/bin/ and optionally sets up the system reaper cron.

readonly SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPTS=("tuku")
readonly INSTALL_DIR="/usr/local/bin"
readonly STATE_DIR="/var/lib/tuku"

# ---------- Colors ----------

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BOLD='\033[1m'
RESET='\033[0m'

check() { printf "${GREEN}  ✓${RESET} %s\n" "$1"; }
warn()  { printf "${YELLOW}  ⚠${RESET} %s\n" "$1"; }
fail()  { printf "${RED}  ✗${RESET} %s\n" "$1"; }
info()  { printf "  %s\n" "$1"; }

# ---------- Usage ----------

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]
       install.sh uninstall [--purge]

System-wide installer for tuku.

Commands:
  (default)       Install scripts to /usr/local/bin/ and create state directories
  uninstall       Remove scripts and optionally purge state

Install Options:
  --with-reaper   Also install the system reaper cron (every 1m, min-age 60m, max-idle 30m)
  --help, -h      Show this help message

Uninstall Options:
  --purge         Also remove /var/lib/tuku/ state directory

What it does:
  1. Copies tuku to /usr/local/bin/
  2. Sets ownership root:root, mode 0755
  3. Creates /var/lib/tuku/ for system-mode state
  4. Optionally installs system reaper cron (--with-reaper)

Must be run as root (sudo ./install.sh).

Examples:
  sudo ./install.sh                  # Install scripts only
  sudo ./install.sh --with-reaper    # Install scripts + system reaper cron
  sudo ./install.sh uninstall        # Remove scripts, keep state
  sudo ./install.sh uninstall --purge  # Remove everything
EOF
    exit 0
}

# ---------- Root check ----------

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        fail "This script must be run as root."
        echo ""
        echo "  Usage: sudo ./install.sh"
        exit 1
    fi
}

# ---------- Install ----------

do_install() {
    local with_reaper=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --with-reaper) with_reaper=true; shift ;;
            --help|-h)     usage ;;
            *)             fail "Unknown option: $1"; echo "  Try: install.sh --help"; exit 1 ;;
        esac
    done

    require_root

    printf "\n${BOLD}Installing tuku...${RESET}\n\n"

    # 1. Copy scripts to /usr/local/bin/
    for script in "${SCRIPTS[@]}"; do
        local src="${SCRIPT_DIR}/${script}"
        local dst="${INSTALL_DIR}/${script}"

        if [[ ! -f "${src}" ]]; then
            fail "Source script not found: ${src}"
            exit 1
        fi

        cp "${src}" "${dst}"
        chown root:root "${dst}"
        chmod 0755 "${dst}"
        check "${script} → ${dst}"
    done

    # 2. Create system state directory (world-readable so non-root users can read .alive files)
    if [[ ! -d "${STATE_DIR}" ]]; then
        mkdir -p "${STATE_DIR}"
        check "Created ${STATE_DIR}/"
    else
        check "${STATE_DIR}/ already exists"
    fi
    chmod 755 "${STATE_DIR}/"
    chmod 755 "${STATE_DIR}/reaper/" 2>/dev/null || true

    # 3. Verify /var/log/ exists (it always should)
    if [[ -d /var/log ]]; then
        check "/var/log/ exists"
    else
        warn "/var/log/ missing (unexpected)"
    fi

    # 4. Optionally install system reaper cron
    if [[ "${with_reaper}" == true ]]; then
        echo ""
        printf "${BOLD}Installing system reaper cron...${RESET}\n"
        "${INSTALL_DIR}/tuku" install --system --interval 1 --min-age 60 --max-idle 30
        check "System reaper cron installed (every 1m, min-age 60m, max-idle 30m)"
        info "Customize with: tuku install --help"
    fi

    # 5. PATH message
    echo ""
    check "Installation complete!"
    echo ""
    info "/usr/local/bin is typically already on PATH."
    info "Verify with: which tuku"
    echo ""
    info "Available commands:"
    info "  tuku            — GPU dashboard (default)"
    info "  tuku reap       — Run idle process detection and cleanup"
    info "  tuku list       — Show all llama.cpp processes with diagnostics"
    info "  tuku install    — Set up automatic reaping via cron"
    info "  tuku kill <PID> — Manually kill a GPU process"
    info "  tuku gpu        — Show all processes using the GPU"
    echo ""
}

# ---------- Uninstall ----------

do_uninstall() {
    local purge=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge) purge=true; shift ;;
            --help|-h) usage ;;
            *)       fail "Unknown option: $1"; exit 1 ;;
        esac
    done

    require_root

    printf "\n${BOLD}Uninstalling tuku...${RESET}\n\n"

    # 1. Remove system cron if it exists
    if [[ -f /etc/cron.d/tuku ]]; then
        "${INSTALL_DIR}/tuku" uninstall --system 2>/dev/null \
            || rm -f /etc/cron.d/tuku
        check "Removed system reaper cron"
    else
        info "No system reaper cron found (skipping)"
    fi

    # 2. Remove scripts from /usr/local/bin/
    for script in "${SCRIPTS[@]}"; do
        local dst="${INSTALL_DIR}/${script}"
        if [[ -f "${dst}" ]]; then
            rm -f "${dst}"
            check "Removed ${dst}"
        else
            info "${dst} not found (skipping)"
        fi
    done

    # 3. Optionally remove state directory
    if [[ "${purge}" == true ]]; then
        if [[ -d "${STATE_DIR}" ]]; then
            rm -rf "${STATE_DIR}"
            check "Purged ${STATE_DIR}/"
        else
            info "${STATE_DIR}/ not found (skipping)"
        fi
    else
        if [[ -d "${STATE_DIR}" ]]; then
            info "State directory preserved: ${STATE_DIR}/"
            info "Use --purge to remove it"
        fi
    fi

    echo ""
    check "Uninstall complete!"
    echo ""
}

# ---------- Main ----------

main() {
    # Handle --help before subcommands
    for arg in "$@"; do
        [[ "${arg}" == "--help" || "${arg}" == "-h" ]] && usage
    done

    if [[ $# -gt 0 ]] && [[ "$1" == "uninstall" ]]; then
        shift
        do_uninstall "$@"
    else
        do_install "$@"
    fi
}

main "$@"
