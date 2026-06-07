#!/bin/bash
#
# uninstall_asl3_weatherapi_v2.sh
#
# KD5FMU Saytime-Weather-2026 Uninstaller
# For Debian 12 / Debian 13 running AllStarLink Version 3
#
# This removes the WeatherAPI/Saytime-Weather-2026 installed files.
# It intentionally DOES NOT remove shared sound files or saytime.pl by default,
# because those may be used by other KD5FMU / AllStarLink projects.
#
# Usage:
#   sudo ./uninstall_asl3_weatherapi_v2.sh
#   sudo ./uninstall_asl3_weatherapi_v2.sh --yes
#   sudo ./uninstall_asl3_weatherapi_v2.sh --yes --purge-config --remove-saytime
#
# Options:
#   -y, --yes          Run without asking confirmation
#   --purge-config    Remove /etc/asterisk/local/weatherapi.ini and tempest.ini
#   --purge-cache     Remove known WeatherAPI cache/temp files
#   --remove-saytime  Remove /usr/local/sbin/saytime.pl
#   --purge-all       Same as --purge-config --purge-cache --remove-saytime
#   -h, --help        Show help
#

set -u

APP_NAME="KD5FMU Saytime-Weather-2026"

SBIN_DIR="/usr/local/sbin"
CONFIG_DIR="/etc/asterisk/local"
SYSTEMD_DIR="/etc/systemd/system"

TIMER_NAME="asl3-weatherapi-update.timer"
SERVICE_NAME="asl3-weatherapi-update.service"

YES=0
PURGE_CONFIG=0
PURGE_CACHE=0
REMOVE_SAYTIME=0

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') uninstaller: $*"
}

warn() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') uninstaller WARNING: $*" >&2
}

die() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') uninstaller ERROR: $*" >&2
    exit 1
}

show_help() {
    sed -n '1,40p' "$0" | sed 's/^# \{0,1\}//'
}

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Please run this uninstaller with sudo or as root."
}

confirm() {
    if [ "$YES" -eq 1 ]; then
        return 0
    fi

    echo
    echo "This will uninstall: $APP_NAME"
    echo
    echo "It will remove:"
    echo "  - WeatherAPI updater scripts from $SBIN_DIR"
    echo "  - systemd service/timer files for $TIMER_NAME"
    echo "  - root crontab entries that call /usr/local/sbin/saytime.pl"
    echo
    echo "It will NOT remove by default:"
    echo "  - $CONFIG_DIR/weatherapi.ini"
    echo "  - $CONFIG_DIR/tempest.ini"
    echo "  - $SBIN_DIR/saytime.pl"
    echo "  - shared sound files in /usr/local/share/asterisk/sounds/custom"
    echo
    read -r -p "Continue with uninstall? [y/N]: " answer
    case "$answer" in
        y|Y|yes|YES) return 0 ;;
        *) die "Uninstall cancelled." ;;
    esac
}

parse_args() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -y|--yes)
                YES=1
                ;;
            --purge-config)
                PURGE_CONFIG=1
                ;;
            --purge-cache)
                PURGE_CACHE=1
                ;;
            --remove-saytime)
                REMOVE_SAYTIME=1
                ;;
            --purge-all)
                PURGE_CONFIG=1
                PURGE_CACHE=1
                REMOVE_SAYTIME=1
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
        shift
    done
}

backup_root_crontab() {
    local backup_file="/root/crontab.before-saytime-weather-uninstall.$(date +%Y%m%d-%H%M%S).bak"

    if crontab -l >/dev/null 2>&1; then
        crontab -l > "$backup_file" || warn "Could not back up root crontab."
        log "Backed up root crontab to $backup_file"
    else
        log "No root crontab found to back up."
    fi
}

remove_saytime_cron_entries() {
    local before after tmpfile
    tmpfile="$(mktemp)"

    before="$(crontab -l 2>/dev/null | wc -l | awk '{print $1}')"

    # Remove active and commented block lines that were used for this installer.
    # This targets only the hourly saytime.pl announcement entry and its matching comment.
    crontab -l 2>/dev/null | \
        grep -v "Hourly Time and Weather Announcement" | \
        grep -v "/usr/local/sbin/saytime\.pl" > "$tmpfile" || true

    if [ -s "$tmpfile" ]; then
        crontab "$tmpfile" || warn "Could not update root crontab."
    else
        crontab -r 2>/dev/null || true
    fi

    after="$(crontab -l 2>/dev/null | wc -l | awk '{print $1}')"
    rm -f "$tmpfile"

    log "Root crontab cleanup complete. Lines before: $before, lines after: $after"
}

stop_disable_systemd_units() {
    if command -v systemctl >/dev/null 2>&1; then
        log "Stopping and disabling $TIMER_NAME and $SERVICE_NAME if present."

        systemctl stop "$TIMER_NAME" 2>/dev/null || true
        systemctl disable "$TIMER_NAME" 2>/dev/null || true
        systemctl stop "$SERVICE_NAME" 2>/dev/null || true
        systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    else
        warn "systemctl not found; skipping systemd stop/disable."
    fi
}

remove_file() {
    local file="$1"
    if [ -e "$file" ] || [ -L "$file" ]; then
        rm -f "$file" && log "Removed $file"
    else
        log "Not found, skipping $file"
    fi
}

remove_dir_if_empty() {
    local dir="$1"
    if [ -d "$dir" ]; then
        rmdir "$dir" 2>/dev/null && log "Removed empty directory $dir" || true
    fi
}

remove_installed_scripts() {
    log "Removing installed WeatherAPI scripts."

    remove_file "$SBIN_DIR/asl3-weatherapi-update.sh"
    remove_file "$SBIN_DIR/weather.sh"
    remove_file "$SBIN_DIR/show_weatherapi.sh"
    remove_file "$SBIN_DIR/random_wx_start.sh"

    if [ "$REMOVE_SAYTIME" -eq 1 ]; then
        remove_file "$SBIN_DIR/saytime.pl"
    else
        log "Preserving $SBIN_DIR/saytime.pl"
    fi
}

remove_systemd_files() {
    log "Removing systemd unit files."

    remove_file "$SYSTEMD_DIR/$SERVICE_NAME"
    remove_file "$SYSTEMD_DIR/$TIMER_NAME"

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
        systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true
        systemctl reset-failed "$TIMER_NAME" 2>/dev/null || true
        log "Reloaded systemd daemon."
    fi
}

remove_config_files() {
    if [ "$PURGE_CONFIG" -eq 1 ]; then
        log "Removing configuration files."

        remove_file "$CONFIG_DIR/weatherapi.ini"
        remove_file "$CONFIG_DIR/tempest.ini"

        # Leave /etc/asterisk/local itself alone. Other ASL3 scripts may use it.
    else
        log "Preserving configuration files. Use --purge-config to remove them."
        log "Preserved $CONFIG_DIR/weatherapi.ini"
        log "Preserved $CONFIG_DIR/tempest.ini"
    fi
}

remove_cache_files() {
    if [ "$PURGE_CACHE" -eq 1 ]; then
        log "Removing known cache/temp files."

        remove_file "/tmp/temperature"
        remove_file "/tmp/condition.gsm"
        remove_file "/tmp/current-time.gsm"

        rm -rf "/var/cache/asl3-saytime-weather" 2>/dev/null && log "Removed /var/cache/asl3-saytime-weather if it existed."
        rm -rf "/var/cache/asl3-weatherapi" 2>/dev/null && log "Removed /var/cache/asl3-weatherapi if it existed."
    else
        log "Preserving cache/temp files. Use --purge-cache to remove known cache files."
    fi
}

show_sound_notice() {
    echo
    echo "======================================================================"
    echo " Shared sound files were NOT removed"
    echo "======================================================================"
    echo
    echo "This installer may have placed or reused recorded sound files here:"
    echo
    echo "  /usr/local/share/asterisk/sounds/custom"
    echo
    echo "Those files are commonly shared by other time/weather announcement"
    echo "projects, so this uninstaller leaves them alone on purpose."
    echo
    echo "That is the safe choice. No need to get froggy and delete your"
    echo "working audio files unless you know they are not used anywhere else."
    echo
    echo "======================================================================"
    echo
}

show_done_message() {
    echo
    echo "======================================================================"
    echo " $APP_NAME uninstall complete"
    echo "======================================================================"
    echo
    echo "Recommended checks:"
    echo
    echo "  systemctl status $TIMER_NAME"
    echo "  sudo crontab -l"
    echo "  ls -l /usr/local/sbin/*weather*"
    echo
    echo "If you preserved the config files, they should still be here:"
    echo
    echo "  $CONFIG_DIR/weatherapi.ini"
    echo "  $CONFIG_DIR/tempest.ini"
    echo
    echo "73!"
    echo "======================================================================"
    echo
}

main() {
    parse_args "$@"
    require_root
    confirm

    backup_root_crontab
    remove_saytime_cron_entries
    stop_disable_systemd_units
    remove_systemd_files
    remove_installed_scripts
    remove_config_files
    remove_cache_files
    show_sound_notice
    show_done_message
}

main "$@"
