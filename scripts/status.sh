#!/bin/zsh
set -euo pipefail

user_home="${HOME:?HOME is required}"
user_id="$(id -u)"
service_label="com.isujin.clock-alarm-volume-guard"
service_target="gui/${user_id}/${service_label}"
installed_binary="${user_home}/Library/Application Support/ClockAlarmVolumeGuard/bin/clock-alarm-volume-guard"
log_directory="${user_home}/Library/Logs/ClockAlarmVolumeGuard"

if launchctl print "$service_target" >/dev/null 2>&1; then
    echo "Service: running"
    launchctl print "$service_target" | /usr/bin/sed -n '/state =/p; /pid =/p; /last exit code =/p'
else
    echo "Service: not loaded"
fi

if [[ -x "$installed_binary" ]]; then
    echo "Doctor:"
    "$installed_binary" doctor
else
    echo "Binary: not installed"
fi

echo "Logs: ${log_directory}"
