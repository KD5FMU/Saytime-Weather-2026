#!/usr/bin/env bash
set -euo pipefail

# ASL3 WeatherAPI Announce installer
# Supports fresh installs and migration from KD5FMU Time-Weather-Announce.
# Uses recorded .gsm sound files, not TTS.

REPO_TARBALL_URL="${TARBALL_URL:-https://github.com/KD5FMU/Saytime-Weather-2026/raw/main/asl3-weatherapi-announce.tar.gz}"
ORIG_BASE_URL="https://raw.githubusercontent.com/KD5FMU/Time-Weather-Announce/refs/heads/main"
ORIG_SAYTIME_URL="$ORIG_BASE_URL/saytime.pl"
ORIG_WEATHER_INI_URL="$ORIG_BASE_URL/weather.ini"
SOUND_ZIP_URL="http://198.58.124.150/tw/sound_files.zip"

LOCATION_ARG="${1:-}"
NODE_ARG="${2:-}"

BIN_DIR="/usr/local/sbin"
LOCAL_DIR="/etc/asterisk/local"
SOUNDS_DIR="/usr/local/share/asterisk/sounds/custom"
SYSTEMD_DIR="/etc/systemd/system"
TMP_DIR="$(mktemp -d)"
BACKUP_ROOT="/root/asl3-weatherapi-announce-backup-$(date +%Y%m%d-%H%M%S)"

log(){ echo "$(date '+%F %T') installer: $*"; }
fatal(){ echo "$(date '+%F %T') installer ERROR: $*" >&2; exit 1; }
cleanup(){ rm -rf "$TMP_DIR"; }
trap cleanup EXIT

[[ "$(id -u)" == "0" ]] || fatal "Please run as root using sudo."

if ! command -v apt-get >/dev/null 2>&1; then
  fatal "This installer expects Debian/ASL3 with apt-get."
fi

log "Installing required packages: curl jq sox cron ca-certificates tar perl unzip"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq sox cron ca-certificates tar perl unzip

mkdir -p "$BIN_DIR" "$LOCAL_DIR" "$SOUNDS_DIR" "$BACKUP_ROOT"

if id asterisk >/dev/null 2>&1; then
  chown asterisk:asterisk "$SOUNDS_DIR" "$LOCAL_DIR" 2>/dev/null || true
fi

# Try to infer location and node from an existing saytime cron line.
CRONTAB_CURRENT="$(crontab -l 2>/dev/null || true)"
INFERRED_LOCATION=""
INFERRED_NODE=""
if [[ -z "$LOCATION_ARG" || -z "$NODE_ARG" ]]; then
  line="$(printf '%s\n' "$CRONTAB_CURRENT" | grep -E 'saytime\.pl[[:space:]]+[^[:space:]]+[[:space:]]+[0-9]+' | head -n1 || true)"
  if [[ -n "$line" ]]; then
    read -r INFERRED_LOCATION INFERRED_NODE < <(printf '%s\n' "$line" | sed -nE 's/.*saytime\.pl[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9]+).*/\1 \2/p')
  fi
fi
LOCATION="${LOCATION_ARG:-${INFERRED_LOCATION:-}}"
NODE_NUMBER="${NODE_ARG:-${INFERRED_NODE:-}}"

EXISTING_TIME_WEATHER="NO"
if [[ -x "$BIN_DIR/saytime.pl" || -f "$BIN_DIR/saytime.pl" ]]; then
  EXISTING_TIME_WEATHER="YES"
fi
if [[ -x "$BIN_DIR/weather.sh" || -f "$BIN_DIR/weather.sh" ]]; then
  EXISTING_TIME_WEATHER="YES"
fi

log "Downloading payload tarball from: $REPO_TARBALL_URL"
curl --fail --location --silent --show-error -o "$TMP_DIR/asl3-weatherapi-announce.tar.gz" "$REPO_TARBALL_URL" || fatal "Could not download payload tarball."
tar -xzf "$TMP_DIR/asl3-weatherapi-announce.tar.gz" -C "$TMP_DIR"
PAYLOAD_DIR="$(find "$TMP_DIR" -maxdepth 1 -type d -name 'asl3_weatherapi_announce_payload' | head -n1)"
[[ -d "$PAYLOAD_DIR" ]] || fatal "Payload directory not found inside tarball."

backup_if_exists(){
  local path="$1"
  if [[ -e "$path" ]]; then
    mkdir -p "$BACKUP_ROOT$(dirname "$path")"
    cp -a "$path" "$BACKUP_ROOT$path"
    log "Backed up $path"
  fi
}

# Install or preserve saytime.pl.
if [[ -f "$BIN_DIR/saytime.pl" ]]; then
  log "Existing saytime.pl found; preserving it."
  backup_if_exists "$BIN_DIR/saytime.pl"
else
  log "No existing saytime.pl found; downloading original KD5FMU/WA3DSP saytime.pl"
  curl --fail --location --silent --show-error -o "$BIN_DIR/saytime.pl" "$ORIG_SAYTIME_URL" || fatal "Could not download original saytime.pl"
  chmod 755 "$BIN_DIR/saytime.pl"
fi

# Ensure saytime.pl points to the custom sound directory used by the original installer.
if grep -q '/var/lib/asterisk/sounds' "$BIN_DIR/saytime.pl"; then
  cp -a "$BIN_DIR/saytime.pl" "$BIN_DIR/saytime.pl.pre-weatherapi.bak.$(date +%Y%m%d-%H%M%S)"
  sed -i 's|/var/lib/asterisk/sounds|/usr/local/share/asterisk/sounds/custom|g' "$BIN_DIR/saytime.pl"
  log "Adjusted saytime.pl sound path to $SOUNDS_DIR"
fi
chmod 755 "$BIN_DIR/saytime.pl"

# Install original recorded sound files if they are missing.
if ! find "$SOUNDS_DIR" -type f -name '*.gsm' | grep -q .; then
  log "Recorded .gsm sound files not found; downloading original sound package."
  curl --fail --location --silent --show-error -o "$TMP_DIR/sound_files.zip" "$SOUND_ZIP_URL" || fatal "Could not download sound_files.zip"
  unzip -o "$TMP_DIR/sound_files.zip" -d "$SOUNDS_DIR" >/dev/null
else
  log "Recorded .gsm sound files already exist; preserving them."
fi

# Preserve old weather.ini if present, create if missing for compatibility.
if [[ ! -f "$LOCAL_DIR/weather.ini" ]]; then
  log "Installing original weather.ini for compatibility."
  curl --fail --location --silent --show-error -o "$LOCAL_DIR/weather.ini" "$ORIG_WEATHER_INI_URL" || true
fi

# Install WeatherAPI config without overwriting existing settings.
if [[ -f "$LOCAL_DIR/weatherapi.ini" ]]; then
  log "Existing weatherapi.ini found; preserving it."
else
  cp "$PAYLOAD_DIR/config/weatherapi.ini" "$LOCAL_DIR/weatherapi.ini"
  if [[ -n "$LOCATION" ]]; then
    sed -i "s|^LOCATION=.*|LOCATION=\"$LOCATION\"|" "$LOCAL_DIR/weatherapi.ini"
  fi
  log "Created $LOCAL_DIR/weatherapi.ini"
fi

if [[ ! -f "$LOCAL_DIR/tempest.ini" ]]; then
  cp "$PAYLOAD_DIR/config/tempest.ini" "$LOCAL_DIR/tempest.ini"
fi

# Replace weather.sh with cache-aware wrapper. Back up the old one first.
backup_if_exists "$BIN_DIR/weather.sh"
install -m 755 "$PAYLOAD_DIR/bin/weather.sh" "$BIN_DIR/weather.sh"
install -m 755 "$PAYLOAD_DIR/bin/asl3-weatherapi-update.sh" "$BIN_DIR/asl3-weatherapi-update.sh"
install -m 755 "$PAYLOAD_DIR/bin/asl3-tempest-update.sh" "$BIN_DIR/asl3-tempest-update.sh"
install -m 755 "$PAYLOAD_DIR/bin/show_weatherapi.sh" "$BIN_DIR/show_weatherapi.sh"
install -m 755 "$PAYLOAD_DIR/bin/random_wx_start.sh" "$BIN_DIR/random_wx_start.sh"

# Install systemd timer/service.
install -m 644 "$PAYLOAD_DIR/systemd/asl3-weatherapi-update.service" "$SYSTEMD_DIR/asl3-weatherapi-update.service"
install -m 644 "$PAYLOAD_DIR/systemd/asl3-weatherapi-update.timer" "$SYSTEMD_DIR/asl3-weatherapi-update.timer"
systemctl daemon-reload
systemctl enable --now asl3-weatherapi-update.timer

# Permissions.
if id asterisk >/dev/null 2>&1; then
  chown asterisk:asterisk "$BIN_DIR/saytime.pl" "$BIN_DIR/weather.sh" "$BIN_DIR/asl3-weatherapi-update.sh" "$BIN_DIR/show_weatherapi.sh" 2>/dev/null || true
  chown -R asterisk:asterisk "$SOUNDS_DIR" 2>/dev/null || true
  chown asterisk:asterisk "$LOCAL_DIR/weatherapi.ini" "$LOCAL_DIR/tempest.ini" 2>/dev/null || true
fi
find "$SOUNDS_DIR" -type d -exec chmod 775 {} \; 2>/dev/null || true
find "$SOUNDS_DIR" -type f -name '*.gsm' -exec chmod 644 {} \; 2>/dev/null || true

# Fresh install: add hourly cron only when location and node are known.
if [[ "$EXISTING_TIME_WEATHER" == "NO" ]]; then
  if [[ -n "$LOCATION" && -n "$NODE_NUMBER" ]]; then
    log "Fresh install detected; adding hourly saytime cron job."
    CRON_COMMENT="# Hourly Time and Weather Announcement"
    CRON_JOB="00 00-23 * * * (/usr/bin/nice -19 /usr/bin/perl $BIN_DIR/saytime.pl $LOCATION $NODE_NUMBER >/dev/null 2>&1)"
    tmpcron="$(mktemp)"
    crontab -l 2>/dev/null > "$tmpcron" || true
    if ! grep -Fq "$CRON_JOB" "$tmpcron"; then
      { echo "$CRON_COMMENT"; echo "$CRON_JOB"; } >> "$tmpcron"
      crontab "$tmpcron"
    fi
    rm -f "$tmpcron"
  else
    log "Fresh install detected, but location/node were not supplied. No hourly cron job was added."
    log "To add one later, run: sudo $0 ZIP_OR_LOCATION NODE_NUMBER"
  fi
else
  log "Migration mode detected; existing saytime cron job was preserved."
fi

# Try initial update only if API key is configured.
if grep -q 'PUT_YOUR_WEATHERAPI_KEY_HERE' "$LOCAL_DIR/weatherapi.ini"; then
  log "WeatherAPI key still needs to be added to $LOCAL_DIR/weatherapi.ini"
else
  log "Running initial weather cache update."
  "$BIN_DIR/asl3-weatherapi-update.sh" || log "Initial update failed; check API key, location, and internet access."
fi

log "Install complete."
log "Edit config: sudo nano $LOCAL_DIR/weatherapi.ini"
log "Test cache: sudo $BIN_DIR/asl3-weatherapi-update.sh && $BIN_DIR/show_weatherapi.sh"
if [[ -n "$LOCATION" && -n "$NODE_NUMBER" ]]; then
  log "Test announce: sudo perl $BIN_DIR/saytime.pl $LOCATION $NODE_NUMBER"
else
  log "Test announce example: sudo perl $BIN_DIR/saytime.pl 74437 YOUR_NODE_NUMBER"
fi
log "Backup location: $BACKUP_ROOT"
