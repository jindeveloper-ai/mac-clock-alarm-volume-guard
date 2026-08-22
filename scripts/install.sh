#!/bin/zsh
set -euo pipefail

script_directory="${0:A:h}"
project_root="${script_directory:h}"
user_home="${HOME:?HOME is required}"
user_id="$(id -u)"
service_label="com.isujin.clock-alarm-volume-guard"
service_target="gui/${user_id}/${service_label}"
install_root="${user_home}/Library/Application Support/ClockAlarmVolumeGuard"
binary_directory="${install_root}/bin"
installed_binary="${binary_directory}/clock-alarm-volume-guard"
log_directory="${user_home}/Library/Logs/ClockAlarmVolumeGuard"
launch_agent_directory="${user_home}/Library/LaunchAgents"
launch_agent_path="${launch_agent_directory}/${service_label}.plist"
template_path="${project_root}/Support/${service_label}.plist.template"

escape_for_sed() {
    /usr/bin/sed 's/[&|]/\\&/g' <<< "$1"
}

echo "Building release binary..."
swift build --package-path "$project_root" -c release
release_binary="${project_root}/.build/release/clock-alarm-volume-guard"

if launchctl print "$service_target" >/dev/null 2>&1; then
    launchctl bootout "gui/${user_id}" "$launch_agent_path" >/dev/null 2>&1 || true
fi

if [[ -x "$installed_binary" ]]; then
    "$installed_binary" restore
fi

/usr/bin/install -d -m 700 "$install_root" "$binary_directory" "$log_directory"
/usr/bin/install -d -m 755 "$launch_agent_directory"
/usr/bin/install -m 755 "$release_binary" "$installed_binary"

temporary_plist="$(mktemp "${launch_agent_path}.tmp.XXXXXX")"
trap '/bin/rm -f -- "$temporary_plist"' EXIT

program_path_escaped="$(escape_for_sed "$installed_binary")"
stdout_path_escaped="$(escape_for_sed "${log_directory}/stdout.log")"
stderr_path_escaped="$(escape_for_sed "${log_directory}/stderr.log")"
/usr/bin/sed \
    -e "s|__PROGRAM_PATH__|${program_path_escaped}|g" \
    -e "s|__STDOUT_PATH__|${stdout_path_escaped}|g" \
    -e "s|__STDERR_PATH__|${stderr_path_escaped}|g" \
    "$template_path" > "$temporary_plist"

/usr/bin/plutil -lint "$temporary_plist"
/bin/chmod 600 "$temporary_plist"
/bin/mv -f "$temporary_plist" "$launch_agent_path"
trap - EXIT

echo "Running read-only doctor check..."
"$installed_binary" doctor

launchctl bootstrap "gui/${user_id}" "$launch_agent_path"
launchctl kickstart -k "$service_target"

echo "Installed and started ${service_label}."
echo "Logs: ${log_directory}"
