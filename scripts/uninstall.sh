#!/bin/zsh
set -euo pipefail

user_home="${HOME:?HOME is required}"
user_id="$(id -u)"
service_label="com.isujin.clock-alarm-volume-guard"
service_target="gui/${user_id}/${service_label}"
expected_install_root="${user_home}/Library/Application Support/ClockAlarmVolumeGuard"
install_root="$expected_install_root"
installed_binary="${install_root}/bin/clock-alarm-volume-guard"
log_directory="${user_home}/Library/Logs/ClockAlarmVolumeGuard"
launch_agent_path="${user_home}/Library/LaunchAgents/${service_label}.plist"
purge_logs=false

if [[ "${1:-}" == "--purge-logs" ]]; then
    purge_logs=true
elif [[ $# -gt 0 ]]; then
    echo "Usage: $0 [--purge-logs]" >&2
    exit 2
fi

if [[ "$install_root" != "$expected_install_root" || -z "$user_home" ]]; then
    echo "Refusing to remove an unexpected install path." >&2
    exit 1
fi

if launchctl print "$service_target" >/dev/null 2>&1; then
    launchctl bootout "gui/${user_id}" "$launch_agent_path" >/dev/null 2>&1 || true
fi

if [[ -x "$installed_binary" ]]; then
    "$installed_binary" restore
fi

/bin/rm -f -- "$launch_agent_path"
/bin/rm -rf -- "$install_root"

if $purge_logs; then
    expected_log_directory="${user_home}/Library/Logs/ClockAlarmVolumeGuard"
    if [[ "$log_directory" != "$expected_log_directory" ]]; then
        echo "Refusing to remove an unexpected log path." >&2
        exit 1
    fi
    /bin/rm -rf -- "$log_directory"
    echo "Removed service files and logs. These files are not recoverable from this script."
else
    echo "Removed service files. Logs were retained at: ${log_directory}"
fi
