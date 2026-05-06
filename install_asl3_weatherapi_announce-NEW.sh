#!/usr/bin/env bash
set -Eeuo pipefail

# ASL3 WeatherAPI Announce installer for Debian 12/13 + AllStarLink 3
# Works as both a migration installer and a fresh installer.
# Migration mode preserves an existing KD5FMU/WA3DSP saytime.pl installation.

REPO_TARBALL_URL="${REPO_TARBALL_URL:-https://github.com/KD5FMU/ASL3-WeatherAPI-Announce/raw/main/asl3-weatherapi-announce.tar.gz}"
WORKDIR="$(mktemp -d /tmp/asl3-weatherapi-install.XXXXXX)"
BACKUP_DIR="/root/asl3-weatherapi-backup-$(date +%F-%H%M%S)"
LOG="/var/log/asl3-weatherapi-announce-install.log"

REQUESTED_LOCATION="${1:-}"
REQUESTED_NODE="${2:-}"

log(){ echo "$(date '+%F %T') installer: $*" | tee -a "$LOG"; }
fail(){ log "ERROR: $*"; exit 1; }
cleanup(){ rm -rf "$WORKDIR"; }
trap cleanup EXIT

[[ $EUID -eq 0 ]] || fail "Run this installer with sudo or as root."

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  [[ "${ID:-}" == "debian" ]] || log "NOTICE: This was designed for Debian. Detected ID=${ID:-unknown}."
  if [[ "${VERSION_ID:-}" != "12" && "${VERSION_ID:-}" != "13" ]]; then
    log "NOTICE: This was designed for Debian 12/13. Detected VERSION_ID=${VERSION_ID:-unknown}. Continuing."
  fi
fi

if ! command -v asterisk >/dev/null 2>&1; then
  log "NOTICE: asterisk command not found. Is ASL3 installed? Continuing because this package only updates scripts and config."
fi

log "Installing required packages: curl jq sox espeak-ng cron ca-certificates tar perl"
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y curl jq sox espeak-ng cron ca-certificates tar perl

mkdir -p /etc/asterisk/local /usr/local/sbin "$BACKUP_DIR"

# Detect previous KD5FMU/Time-Weather-Announce style install.
EXISTING_SAYTIME="NO"
EXISTING_WEATHER="NO"
EXISTING_CRON="NO"
[[ -f /usr/local/sbin/saytime.pl ]] && EXISTING_SAYTIME="YES"
[[ -f /usr/local/sbin/weather.sh ]] && EXISTING_WEATHER="YES"
crontab -l 2>/dev/null | grep -qE '/usr/(local/)?sbin/(perl )?saytime\.pl|/usr/bin/perl /usr/local/sbin/saytime\.pl|Hourly Time and Weather Announcement' && EXISTING_CRON="YES" || true

if [[ "$EXISTING_SAYTIME" == "YES" || "$EXISTING_WEATHER" == "YES" || "$EXISTING_CRON" == "YES" ]]; then
  log "Detected existing Time-Weather-Announce style install. Migration mode enabled. Existing saytime.pl will be preserved."
else
  log "No existing Time-Weather-Announce install detected. Fresh install mode enabled."
fi

# Try to infer location and node from existing root crontab if args were not supplied.
if [[ -z "$REQUESTED_LOCATION" || -z "$REQUESTED_NODE" ]]; then
  CRON_LINE="$(crontab -l 2>/dev/null | grep -E 'saytime\.pl[[:space:]]+[^[:space:]]+[[:space:]]+[0-9]+' | head -n1 || true)"
  if [[ -n "$CRON_LINE" ]]; then
    INFERRED_LOCATION="$(echo "$CRON_LINE" | sed -nE 's/.*saytime\.pl[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9]+).*/\1/p')"
    INFERRED_NODE="$(echo "$CRON_LINE" | sed -nE 's/.*saytime\.pl[[:space:]]+([^[:space:]]+)[[:space:]]+([0-9]+).*/\2/p')"
    [[ -z "$REQUESTED_LOCATION" && -n "$INFERRED_LOCATION" ]] && REQUESTED_LOCATION="$INFERRED_LOCATION"
    [[ -z "$REQUESTED_NODE" && -n "$INFERRED_NODE" ]] && REQUESTED_NODE="$INFERRED_NODE"
    log "Inferred existing announcement settings: LOCATION=${REQUESTED_LOCATION:-unknown}, NODE=${REQUESTED_NODE:-unknown}"
  fi
fi

log "Downloading package from: $REPO_TARBALL_URL"
curl -fL --retry 3 --connect-timeout 20 "$REPO_TARBALL_URL" -o "$WORKDIR/asl3-weatherapi-announce.tar.gz" || fail "Download failed"

tar -tzf "$WORKDIR/asl3-weatherapi-announce.tar.gz" >/dev/null || fail "Tarball validation failed"
tar -xzf "$WORKDIR/asl3-weatherapi-announce.tar.gz" -C "$WORKDIR"
PAYLOAD="$WORKDIR/asl3_weatherapi_announce_payload"
[[ -d "$PAYLOAD" ]] || fail "Payload directory not found inside tarball"

log "Backing up existing files to $BACKUP_DIR"
crontab -l 2>/dev/null > "$BACKUP_DIR/root-crontab-before.txt" || true
for f in \
  /usr/local/sbin/saytime.pl \
  /usr/local/sbin/weather.sh \
  /usr/local/sbin/asl3-weatherapi-update.sh \
  /usr/local/sbin/asl3-tempest-update.sh \
  /usr/local/sbin/random_wx_start.sh \
  /usr/local/sbin/show_weatherapi.sh \
  /etc/asterisk/local/weather.ini \
  /etc/asterisk/local/weatherapi.ini \
  /etc/asterisk/local/tempest.ini \
  /etc/systemd/system/asl3-weatherapi-update.service \
  /etc/systemd/system/asl3-weatherapi-update.timer; do
  [[ -e "$f" ]] && cp -a "$f" "$BACKUP_DIR/"
done

log "Installing ASL3 WeatherAPI cache scripts to /usr/local/sbin"
install -m 0755 "$PAYLOAD/bin/asl3-weatherapi-update.sh" /usr/local/sbin/asl3-weatherapi-update.sh
install -m 0755 "$PAYLOAD/bin/asl3-tempest-update.sh" /usr/local/sbin/asl3-tempest-update.sh
install -m 0755 "$PAYLOAD/bin/random_wx_start.sh" /usr/local/sbin/random_wx_start.sh
install -m 0755 "$PAYLOAD/bin/weather.sh" /usr/local/sbin/weather.sh
install -m 0755 "$PAYLOAD/bin/show_weatherapi.sh" /usr/local/sbin/show_weatherapi.sh

if [[ "$EXISTING_SAYTIME" == "YES" ]]; then
  log "Preserving existing /usr/local/sbin/saytime.pl"
else
  log "Installing fallback ASL3 /usr/local/sbin/saytime.pl for fresh installs"
  install -m 0755 "$PAYLOAD/bin/saytime.pl" /usr/local/sbin/saytime.pl
fi

log "Installing default config files without overwriting existing API keys"
if [[ ! -e /etc/asterisk/local/weatherapi.ini ]]; then
  install -m 0640 "$PAYLOAD/config/weatherapi.ini" /etc/asterisk/local/weatherapi.ini
  [[ -n "$REQUESTED_LOCATION" ]] && sed -i "s|^LOCATION=.*|LOCATION=\"$REQUESTED_LOCATION\"|" /etc/asterisk/local/weatherapi.ini

  # Migrate simple old weather.ini values when present.
  if [[ -r /etc/asterisk/local/weather.ini ]]; then
    OLD_TEMP="$(grep -E '^(Temperature_mode|temperature_mode)=' /etc/asterisk/local/weather.ini | tail -n1 | cut -d= -f2- | tr -d '"' || true)"
    OLD_COND="$(grep -E '^(process_condition|PROCESS_CONDITION)=' /etc/asterisk/local/weather.ini | tail -n1 | cut -d= -f2- | tr -d '"' || true)"
    [[ -n "$OLD_TEMP" ]] && sed -i "s|^TEMPERATURE_MODE=.*|TEMPERATURE_MODE=\"$OLD_TEMP\"|" /etc/asterisk/local/weatherapi.ini
    [[ -n "$OLD_COND" ]] && sed -i "s|^PROCESS_CONDITION=.*|PROCESS_CONDITION=\"$OLD_COND\"|" /etc/asterisk/local/weatherapi.ini
  fi
else
  log "Existing /etc/asterisk/local/weatherapi.ini found; preserving it."
fi

[[ -e /etc/asterisk/local/tempest.ini ]] || install -m 0640 "$PAYLOAD/config/tempest.ini" /etc/asterisk/local/tempest.ini
if getent group asterisk >/dev/null 2>&1; then
  chown root:asterisk /etc/asterisk/local/weatherapi.ini /etc/asterisk/local/tempest.ini 2>/dev/null || true
fi

log "Installing systemd timer"
install -m 0644 "$PAYLOAD/systemd/asl3-weatherapi-update.service" /etc/systemd/system/asl3-weatherapi-update.service
install -m 0644 "$PAYLOAD/systemd/asl3-weatherapi-update.timer" /etc/systemd/system/asl3-weatherapi-update.timer
systemctl daemon-reload
systemctl enable --now asl3-weatherapi-update.timer

# Fresh install mode: add hourly announcement cron only when we know the node number.
if [[ "$EXISTING_CRON" == "NO" && -n "$REQUESTED_LOCATION" && -n "$REQUESTED_NODE" ]]; then
  log "Adding hourly announcement cron job for LOCATION=$REQUESTED_LOCATION NODE=$REQUESTED_NODE"
  TMP_CRON="$(mktemp)"
  crontab -l 2>/dev/null > "$TMP_CRON" || true
  {
    echo "# Hourly Time and Weather Announcement"
    echo "00 00-23 * * * (/usr/bin/nice -19 /usr/bin/perl /usr/local/sbin/saytime.pl $REQUESTED_LOCATION $REQUESTED_NODE >/dev/null 2>&1)"
  } >> "$TMP_CRON"
  crontab "$TMP_CRON"
  rm -f "$TMP_CRON"
elif [[ "$EXISTING_CRON" == "YES" ]]; then
  log "Existing hourly announcement cron job detected; leaving it in place."
else
  log "No hourly announcement cron added because LOCATION and NODE_NUMBER were not both supplied."
fi

log "Installation complete."
echo
echo "Mode summary:"
echo "  Existing saytime.pl detected: $EXISTING_SAYTIME"
echo "  Existing hourly cron detected: $EXISTING_CRON"
echo "  Location used for config/cron: ${REQUESTED_LOCATION:-not set}"
echo "  Node used for cron: ${REQUESTED_NODE:-not set}"
echo
echo "Next steps:"
echo "  1. Edit /etc/asterisk/local/weatherapi.ini"
echo "  2. Add your WeatherAPI API_KEY and confirm LOCATION"
echo "  3. Run: sudo /usr/local/sbin/asl3-weatherapi-update.sh"
echo "  4. Run: /usr/local/sbin/show_weatherapi.sh"
echo "  5. Test: sudo /usr/local/sbin/saytime.pl ${REQUESTED_LOCATION:-74437} ${REQUESTED_NODE:-YOUR_NODE_NUMBER}"
echo
echo "Backup folder: $BACKUP_DIR"
