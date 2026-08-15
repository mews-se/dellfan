#!/bin/bash

# Bash script to control fan speed based on CPU temperature.
# Finds the coretemp hwmon device automatically, uses hysteresis to avoid
# fan oscillation, and only calls i8kfan when the fan level actually changes.

SENSOR_NAME="coretemp"  # hwmon device name to read temperature from
INTERVAL=2              # seconds between temperature checks

# Control temperatures in C: the fan starts at LOW, runs full from HIGH.
# dellfan temps writes /etc/dellfan.conf; without it the defaults apply.
LOW=40
HIGH=50
# shellcheck source=/dev/null
[ -r /etc/dellfan.conf ] && . /etc/dellfan.conf

# Thresholds in millidegrees Celsius. Separate up/down limits (hysteresis)
# keep the fan from toggling back and forth when the temperature hovers
# right at a threshold.
LEVEL1_UP=$((LOW * 1000))
LEVEL1_DOWN=$(((LOW - 3) * 1000))
LEVEL2_UP=$((HIGH * 1000))
LEVEL2_DOWN=$(((HIGH - 3) * 1000))

# Failsafe: never leave the machine without cooling. Whatever makes this
# script exit (sensor error, systemctl stop, crash), set both fans to max.
trap '/usr/bin/i8kfan 2 2 > /dev/null; exit' EXIT INT TERM

# Locate the sensor by hwmon name instead of a hardcoded hwmon number,
# which changes between boots depending on module load order.
sensor=""
for d in /sys/class/hwmon/hwmon*; do
  if [ -r "$d/name" ] && [ "$(cat "$d/name")" = "$SENSOR_NAME" ]; then
    sensor="$d/temp1_input"
    break
  fi
done

if [ -z "$sensor" ] || [ ! -r "$sensor" ]; then
  echo "Error: no readable temp1_input on a hwmon device named '$SENSOR_NAME'." >&2
  exit 1
fi

level=-1  # unknown; forces an i8kfan call on the first iteration

while true; do
  if ! read -r temp < "$sensor"; then
    echo "Error: unable to read $sensor." >&2
    exit 1
  fi

  if [ "$temp" -ge "$LEVEL2_UP" ]; then
    new_level=2
  elif [ "$level" -eq 2 ] && [ "$temp" -ge "$LEVEL2_DOWN" ]; then
    new_level=2
  elif [ "$temp" -ge "$LEVEL1_UP" ]; then
    new_level=1
  elif [ "$level" -ge 1 ] && [ "$temp" -ge "$LEVEL1_DOWN" ]; then
    new_level=1
  else
    new_level=0
  fi

  # i8k SMM calls briefly stall the CPU, so skip them when nothing changed.
  if [ "$new_level" -ne "$level" ]; then
    /usr/bin/i8kfan - "$new_level" > /dev/null
    level=$new_level
  fi

  sleep "$INTERVAL"
done
