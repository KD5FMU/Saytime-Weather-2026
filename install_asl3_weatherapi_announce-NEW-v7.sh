#!/bin/bash
# install_asl3_weatherapi_announce-NEW.sh
# KD5FMU Saytime Weather 2026 - ASL3 WeatherAPI cached weather installer
# v7: prefers local tarball first and force-installs ASL3-patched WA3DSP say24time.pl from tarball.

set -u

REPO_TARBALL_URL="https://github.com/KD5FMU/Saytime-Weather-2026/raw/main/asl3-weatherapi-announce.tar.gz"
ORIGINAL_SOUND_ZIP_URL="http://198.58.124.150/tw/sound_files.zip"

PAYLOAD_TAR="/tmp/asl3-weatherapi-announce.tar.gz"
WORKDIR="/tmp/asl3-weatherapi-install.$$"
PAYLOAD_DIR="$WORKDIR/asl3_weatherapi_announce_payload"

CONFIG_DIR="/etc/asterisk/local"
CONFIG_FILE="$CONFIG_DIR/weatherapi.ini"
TEMP_CONFIG_FILE="$CONFIG_DIR/tempest.ini"
SOUNDS_DIR="/usr/local/share/asterisk/sounds/custom"
SBIN_DIR="/usr/local/sbin"
SYSTEMD_DIR="/etc/systemd/system"

LOCATION_ARG="${1:-}"
NODE_ARG="${2:-}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') installer: $*"; }
die() { echo "$(date '+%Y-%m-%d %H:%M:%S') installer ERROR: $*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || die "Please run this installer with sudo or as root."
}

backup_file() {
    local file="$1"
    [ -f "$file" ] && cp -a "$file" "$file.bak.$(date +%Y%m%d-%H%M%S)"
}

install_packages() {
    log "Installing required packages: curl jq sox cron ca-certificates tar perl unzip"
    apt-get update || die "apt-get update failed."
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq sox cron ca-certificates tar perl unzip || die "Package install failed."
}

detect_existing_values_from_cron() {
    local cron_text detected
    cron_text="$(crontab -l 2>/dev/null || true)"
    detected="$(echo "$cron_text" | awk '/say24time\.pl/ { for (i=1; i<=NF; i++) { if ($i ~ /say24time\.pl$/) { if ((i+2)<=NF) { gsub(/[^A-Za-z0-9.,_-]/, "", $(i+1)); gsub(/[^0-9]/, "", $(i+2)); print $(i+1) " " $(i+2); exit } } } }')"
    if [ -n "$detected" ]; then
        [ -z "$LOCATION_ARG" ] && LOCATION_ARG="$(echo "$detected" | awk '{print $1}')"
        [ -z "$NODE_ARG" ] && NODE_ARG="$(echo "$detected" | awk '{print $2}')"
    fi
}

download_payload() {
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"

    # Prefer a tarball in the same directory as this installer.
    # This prevents accidentally testing a new installer against an older GitHub tarball.
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    LOCAL_TARBALL="$SCRIPT_DIR/asl3-weatherapi-announce.tar.gz"

    if [ -f "$LOCAL_TARBALL" ]; then
        log "Using local package tarball: $LOCAL_TARBALL"
        cp -f "$LOCAL_TARBALL" "$PAYLOAD_TAR" || die "Could not copy local tarball."
    else
        log "Local tarball not found beside installer; downloading ASL3 WeatherAPI package from GitHub"
        curl -fL "$REPO_TARBALL_URL" -o "$PAYLOAD_TAR" || die "Could not download tarball from $REPO_TARBALL_URL"
    fi

    tar xzf "$PAYLOAD_TAR" -C "$WORKDIR" || die "Could not extract payload tarball."
    [ -d "$PAYLOAD_DIR" ] || die "Payload directory not found inside tarball."

    if [ ! -f "$PAYLOAD_DIR/bin/say24time.pl" ]; then
        echo
        echo "The tarball being used does NOT contain bin/say24time.pl."
        echo
        echo "Fix:"
        echo "  1. Upload the newest asl3-weatherapi-announce.tar.gz to GitHub, OR"
        echo "  2. Put the newest asl3-weatherapi-announce.tar.gz in the same directory as this installer."
        echo
        die "say24time.pl is missing from the package tarball."
    fi
}

install_weather_scripts() {
    log "Installing ASL3 WeatherAPI scripts"
    install -m 0755 "$PAYLOAD_DIR/bin/asl3-weatherapi-update.sh" "$SBIN_DIR/asl3-weatherapi-update.sh"
    install -m 0755 "$PAYLOAD_DIR/bin/weather.sh" "$SBIN_DIR/weather.sh"
    install -m 0755 "$PAYLOAD_DIR/bin/show_weatherapi.sh" "$SBIN_DIR/show_weatherapi.sh"
    install -m 0755 "$PAYLOAD_DIR/bin/random_wx_start.sh" "$SBIN_DIR/random_wx_start.sh"
}

install_say24time() {
    log "Installing ASL3-patched say24time.pl"
    backup_file "$SBIN_DIR/say24time.pl"
    install -m 0755 "$PAYLOAD_DIR/bin/say24time.pl" "$SBIN_DIR/say24time.pl"
    chmod 0755 "$SBIN_DIR/say24time.pl"
    [ -f "$SBIN_DIR/say24time.pl" ] || die "Failed to install $SBIN_DIR/say24time.pl"
}

install_config_files() {
    mkdir -p "$CONFIG_DIR"

    if [ ! -f "$CONFIG_FILE" ]; then
        log "Creating $CONFIG_FILE"
        install -m 0640 "$PAYLOAD_DIR/config/weatherapi.ini" "$CONFIG_FILE"
        [ -n "$LOCATION_ARG" ] && sed -i "s/^LOCATION=.*/LOCATION=\"$LOCATION_ARG\"/" "$CONFIG_FILE"
    else
        log "$CONFIG_FILE already exists; preserving it."
    fi

    if [ ! -f "$TEMP_CONFIG_FILE" ]; then
        log "Creating $TEMP_CONFIG_FILE"
        install -m 0640 "$PAYLOAD_DIR/config/tempest.ini" "$TEMP_CONFIG_FILE"
    else
        log "$TEMP_CONFIG_FILE already exists; preserving it."
    fi
}

install_sound_files_if_needed() {
    mkdir -p "$SOUNDS_DIR"

    local count
    count="$(find "$SOUNDS_DIR" -maxdepth 1 -type f -name '*.gsm' 2>/dev/null | wc -l | awk '{print $1}')"

    if [ "$count" -ge 20 ]; then
        log "Recorded sound files appear to already exist in $SOUNDS_DIR; skipping sound download."
        return 0
    fi

    log "Downloading original recorded sound files"
    local zip="/tmp/sound_files.zip"
    curl -fL "$ORIGINAL_SOUND_ZIP_URL" -o "$zip" || die "Could not download sound files from $ORIGINAL_SOUND_ZIP_URL"
    unzip -o "$zip" -d "$SOUNDS_DIR" >/dev/null || die "Could not extract sound files to $SOUNDS_DIR"
    chown -R asterisk:asterisk "$SOUNDS_DIR" 2>/dev/null || true
    chmod -R a+rX "$SOUNDS_DIR"
}

install_systemd_timer() {
    log "Installing systemd timer/service for randomized weather cache updates"
    install -m 0644 "$PAYLOAD_DIR/systemd/asl3-weatherapi-update.service" "$SYSTEMD_DIR/asl3-weatherapi-update.service"
    install -m 0644 "$PAYLOAD_DIR/systemd/asl3-weatherapi-update.timer" "$SYSTEMD_DIR/asl3-weatherapi-update.timer"
    systemctl daemon-reload
    systemctl enable --now asl3-weatherapi-update.timer || die "Could not enable/start asl3-weatherapi-update.timer"
}

any_say24time_cron_exists() {
    crontab -l 2>/dev/null | grep -q "say24time\.pl"
}

add_announcement_cron_if_needed() {
    if any_say24time_cron_exists; then
        log "A say24time.pl crontab entry already exists; leaving it unchanged."
        return 0
    fi

    if [ -z "$LOCATION_ARG" ] || [ -z "$NODE_ARG" ]; then
        log "No existing say24time.pl cron entry found."
        log "Location and node number were not both supplied, so I cannot safely add the announcement cron entry."
        log "To auto-add it, rerun as: sudo ./install_asl3_weatherapi_announce-NEW.sh ZIP_OR_LOCATION NODE_NUMBER"
        log "Manual example: 0 * * * * /usr/bin/perl /usr/local/sbin/say24time.pl ZIP_OR_LOCATION NODE_NUMBER >/dev/null 2>&1"
        return 0
    fi

    local newline="0 * * * * /usr/bin/perl /usr/local/sbin/say24time.pl $LOCATION_ARG $NODE_ARG >/dev/null 2>&1"

    log "Adding hourly announcement crontab entry using say24time.pl for location $LOCATION_ARG and node $NODE_ARG"
    (crontab -l 2>/dev/null; echo "$newline") | crontab - || die "Could not add root crontab entry."
}

show_config_notice() {
    echo
    echo "======================================================================"
    echo " IMPORTANT: WeatherAPI configuration needed"
    echo "======================================================================"
    echo
    echo " Edit this file and add your WeatherAPI.com API key and location:"
    echo
    echo "   sudo nano $CONFIG_FILE"
    echo
    echo " Set these values:"
    echo
    echo "   API_KEY=\"your_weatherapi_api_key_here\""
    echo "   LOCATION=\"74437\""
    echo
    echo " You can get an API key from:"
    echo "   https://www.weatherapi.com/"
    echo
    echo " Then test with:"
    echo
    echo "   sudo /usr/local/sbin/asl3-weatherapi-update.sh"
    echo "   /usr/local/sbin/show_weatherapi.sh"
    echo "   sudo perl /usr/local/sbin/say24time.pl ${LOCATION_ARG:-ZIP_OR_LOCATION} ${NODE_ARG:-NODE_NUMBER}"
    echo
    echo " Confirm say24time.pl installed:"
    echo
    echo "   ls -l /usr/local/sbin/say24time.pl"
    echo
    echo "======================================================================"
    echo
}

main() {
    require_root
    detect_existing_values_from_cron
    install_packages
    download_payload
    install_weather_scripts
    install_say24time
    install_config_files
    install_sound_files_if_needed
    install_systemd_timer
    add_announcement_cron_if_needed
    show_config_notice
    log "Install complete."
}

main "$@"
