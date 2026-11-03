#!/bin/bash
# Resize existing Tart runner daemons and install their daily image updater.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/tart-common.sh"

usage() {
    cat <<'USAGE'
Usage: sudo bash tart-configure-runners.sh <runner-count> <memory-gib>

Example: sudo bash tart-configure-runners.sh 2 8

Sets 8 GiB for existing com.github.tart-runner-1 and -2 services, restarts
them, and installs the daily image updater with a separate 4 GiB budget.
Services must already be installed and loaded as system LaunchDaemons.
Running jobs are interrupted. This does not provision a new machine.
USAGE
}

if [ "${1:-}" = --help ] || [ "${1:-}" = -h ]; then usage; exit 0; fi
[ "$#" -eq 2 ] || { usage >&2; die "Provide a runner count and memory size in GiB."; }
count="$1"
memory_gib="$2"
[[ "$count" =~ ^[1-9][0-9]*$ ]] && [ "${#count}" -le 6 ] \
    || die "Runner count must be a positive integer of at most six digits."
[[ "$memory_gib" =~ ^[1-9][0-9]*$ ]] && [ "${#memory_gib}" -le 6 ] \
    || die "Memory must be a positive integer in GiB of at most six digits."
[ "$(uname -s)" = Darwin ] || die "This script supports macOS only."
[ "$(id -u)" -eq 0 ] || die "Run this script with sudo."
for command_name in plutil launchctl jq; do require_cmd "$command_name"; done

memory_mb=$((memory_gib * 1024))
host_bytes="$(sysctl -n hw.memsize)"
[[ "$host_bytes" =~ ^[1-9][0-9]*$ ]] || die "Could not read host memory."
host_mb=$((host_bytes / 1024 / 1024))
requested_mb=$((count * memory_mb + 4096))
if [ "$requested_mb" -ge "$host_mb" ]; then
    die "${count} runner(s) at ${memory_gib} GiB plus the 4 GiB updater leave no RAM for macOS. Reduce the count or memory."
fi

runner_user=""
shared_settings=""
for ((i = 1; i <= count; i++)); do
    label="com.github.tart-runner-$i"
    plist="/Library/LaunchDaemons/$label.plist"
    [ -f "$plist" ] && [ ! -L "$plist" ] || die "Missing or unsafe service file: $plist"
    plutil -lint "$plist" >/dev/null
    service="$(plutil -convert json -o - "$plist")"
    actual_label="$(printf '%s' "$service" | jq -er '.Label')"
    [ "$actual_label" = "$label" ] || die "Unexpected service label in $plist"
    settings="$(printf '%s' "$service" | jq -ce --arg loop "$SCRIPT_DIR/tart-runner-loop.sh" '
        .ProgramArguments as $args |
        if ($args | index($loop)) == null then
            error("Service must use tart-runner-loop.sh from this checkout")
        else {
            user: .UserName,
            image: ($args | index("--golden-image") as $i |
                if $i == null then "gha-ubuntu-kvm" else .[$i + 1] end),
            config: (.EnvironmentVariables.TART_RUNNER_CONFIG_DIR // ""),
            key: (.EnvironmentVariables.TART_SSH_KEY // ""),
            guest_user: (.EnvironmentVariables.TART_GUEST_USER // "admin"),
            guest_runner: (.EnvironmentVariables.TART_GUEST_RUNNER_DIR // "/opt/actions-runner")
        } end
    ')" || die "Could not read runner settings from $plist"
    printf '%s' "$settings" | jq -e '
        (.image | type == "string" and test("^[a-zA-Z0-9._-]+$")) and
        all([.config, .key, .guest_user, .guest_runner][]; type == "string")
    ' >/dev/null || die "Invalid image or guest connection settings in $plist"
    user="$(printf '%s' "$settings" | jq -er '.user | select(type == "string" and length > 0)')"
    [ -n "$user" ] && [ "$user" != root ] || die "Service must run as a non-root Tart owner: $label"
    if [ -z "$runner_user" ]; then runner_user="$user"; fi
    if [ -z "$shared_settings" ]; then shared_settings="$settings"; fi
    [ "$settings" = "$shared_settings" ] \
        || die "All selected runners must share the same Tart owner, image and guest connection settings."
    launchctl print "system/$label" >/dev/null \
        || die "Service is not loaded: $label. Load it before running this script."
done

log "Restarting ${count} runner(s) with ${memory_gib} GiB each; running jobs will be interrupted."
for ((i = 1; i <= count; i++)); do
    label="com.github.tart-runner-$i"
    plist="/Library/LaunchDaemons/$label.plist"
    log "Updating $label to ${memory_mb} MiB."
    plutil -replace EnvironmentVariables.TART_GUEST_MEMORY_MB -string "$memory_mb" "$plist"
    plutil -lint "$plist" >/dev/null
    launchctl bootout "system/$label"
    launchctl bootstrap system "$plist"
    launchctl print "system/$label" >/dev/null
done

image="$(printf '%s' "$shared_settings" | jq -r '.image')"
TART_UPDATE_MEMORY_MB=4096 \
TART_RUNNER_CONFIG_DIR="$(printf '%s' "$shared_settings" | jq -r '.config')" \
TART_SSH_KEY="$(printf '%s' "$shared_settings" | jq -r '.key')" \
TART_GUEST_USER="$(printf '%s' "$shared_settings" | jq -r '.guest_user')" \
TART_GUEST_RUNNER_DIR="$(printf '%s' "$shared_settings" | jq -r '.guest_runner')" \
    bash "$SCRIPT_DIR/tart-install-image-updater.sh" --launchd-user "$runner_user" \
        --golden-image "$image"
log "Configured ${count} runner(s) at ${memory_gib} GiB each and installed daily image updates at 4 GiB."
log "New job VMs use the allocation immediately after boot; verify with: tart get ${image}-runner-1"
