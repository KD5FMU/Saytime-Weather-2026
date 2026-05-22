#!/bin/bash

CONFIG="/etc/asterisk/local/weatherapi.ini"
SOUNDS="/usr/local/share/asterisk/sounds/custom"
OUTDIR="/tmp"

# Load config
if [ -f "$CONFIG" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG"
fi

# Default to Fahrenheit if not set
TEMPERATURE_MODE="${TEMPERATURE_MODE:-F}"

# Normalize temperature mode to uppercase
TEMPERATURE_MODE="$(echo "$TEMPERATURE_MODE" | tr '[:lower:]' '[:upper:]')"

# Refresh WeatherAPI cache
/usr/local/sbin/asl3-weatherapi-update.sh >/dev/null 2>&1

# Read the already-working display output
WEATHER_OUTPUT="$(/usr/local/sbin/show_weatherapi.sh 2>/dev/null)"

# Select the correct temperature line based on weatherapi.ini
if [ "$TEMPERATURE_MODE" = "C" ]; then
    TEMP="$(echo "$WEATHER_OUTPUT" | awk -F: '/Temp C:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')"
else
    TEMP="$(echo "$WEATHER_OUTPUT" | awk -F: '/Temp F:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')"
fi

CONDITION="$(echo "$WEATHER_OUTPUT" | awk -F: '/Condition:/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')"

# Round and write temperature
if [ -n "$TEMP" ] && [ "$TEMP" != "null" ]; then
    printf "%.0f\n" "$TEMP" > "$OUTDIR/temperature"
fi

# Normalize condition
condition_lc="$(echo "$CONDITION" | tr '[:upper:]' '[:lower:]')"

condition_file=""

case "$condition_lc" in
    *sunny*)
        condition_file="sunny.gsm"
        ;;
    *clear*)
        condition_file="clear.gsm"
        ;;
    *partly*cloudy*|*cloudy*|*overcast*)
        condition_file="cloudy.gsm"
        ;;
    *mist*|*fog*)
        condition_file="fog.gsm"
        ;;
    *rain*|*drizzle*|*shower*)
        condition_file="rain.gsm"
        ;;
    *thunder*)
        condition_file="thunderstorm.gsm"
        ;;
    *snow*|*sleet*|*ice*)
        condition_file="snow.gsm"
        ;;
esac

# Create condition.gsm
if [ -n "$condition_file" ] && [ -f "$SOUNDS/$condition_file" ]; then
    cp "$SOUNDS/$condition_file" "$OUTDIR/condition.gsm"
fi

chmod 644 "$OUTDIR/temperature" "$OUTDIR/condition.gsm" 2>/dev/null

exit 0
