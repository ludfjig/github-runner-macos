#!/bin/bash
# Resize existing Tart runner daemons and install their daily image updater.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/tart-common.sh"

usage() {
    cat <<'USAGE'
Usage: sudo bash tart-configure-runners.sh <runner-count> <memory-gib> [options]

  --labels <csv>       Replace saved custom runner labels, preserving other args.
  --force              Override ONLY the host memory budget refusal.
  --daily-at <HH:MM>    Schedule updates at this local time, without running at load.

Example: sudo bash tart-configure-runners.sh 2 6 --force --labels arm64,kvm,linux --daily-at 03:00

Sets RAM for existing services and installs an updater with a separate 4 GiB
budget. Without --daily-at, the updater starts immediately and every 24 hours.
Services must already be installed and loaded as system LaunchDaemons.
Running jobs are interrupted. This does not provision a new machine.
USAGE
}

force=false
labels=""
daily_at=""
positionals=()
while [ "$#" -gt 0 ]; do
    case "$1" in
        --force)
            force=true
            shift
            ;;
        --labels)
            [ "$#" -ge 2 ] || die "--labels requires a non-empty comma-separated list."
            labels="$2"
            [[ "$labels" =~ ^[a-zA-Z0-9._-]+(,[a-zA-Z0-9._-]+)*$ ]] ||
                die "--labels requires a non-empty comma-separated list of label names."
            shift 2
            ;;
        --daily-at)
            [ "$#" -ge 2 ] || die "--daily-at requires HH:MM."
            daily_at="$2"
            [[ "$daily_at" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || die "--daily-at requires HH:MM (00:00..23:59)."
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        --*) die "Unknown argument: $1" ;;
        *)
            positionals+=("$1")
            shift
            ;;
    esac
done
[ "${#positionals[@]}" -eq 2 ] || {
    usage >&2
    die "Provide a runner count and memory size in GiB."
}
count="${positionals[0]}"
memory_gib="${positionals[1]}"
[[ "$count" =~ ^[1-9][0-9]*$ ]] && [ "${#count}" -le 6 ] ||
    die "Runner count must be a positive integer of at most six digits."
[[ "$memory_gib" =~ ^[1-9][0-9]*$ ]] && [ "${#memory_gib}" -le 6 ] ||
    die "Memory must be a positive integer in GiB of at most six digits."
[ "$(uname -s)" = Darwin ] || die "This script supports macOS only."
[ "$(id -u)" -eq 0 ] || die "Run this script with sudo."
for command_name in plutil launchctl jq; do require_cmd "$command_name"; done

memory_mb=$((memory_gib * 1024))
host_bytes="$(sysctl -n hw.memsize)"
[[ "$host_bytes" =~ ^[1-9][0-9]*$ ]] || die "Could not read host memory."
host_mb=$((host_bytes / 1024 / 1024))
requested_mb=$((count * memory_mb + 4096))
if [ "$requested_mb" -ge "$host_mb" ]; then
    if [ "$force" = false ]; then
        die "${count} runner(s) at ${memory_gib} GiB plus the 4 GiB updater leave no RAM for macOS. Reduce the count or memory, or explicitly use --force."
    fi
    log "WARNING: --force host memory overcommit: jobs=$((count * memory_mb)) MiB (${count} x ${memory_gib} GiB), updater=4096 MiB, host=${host_mb} MiB, macOS headroom=$((host_mb - requested_mb)) MiB."
    log "WARNING: Guest swap is not host RAM. Jobs and updates may overlap; memory pressure, stalls or VM failures remain possible."
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
        if ($args | type != "array") or (all($args[]; type == "string") | not) then
            error("Invalid service arguments")
        elif ($args | index($loop)) == null then
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
    [ "$settings" = "$shared_settings" ] ||
        die "All selected runners must share the same Tart owner, image and guest connection settings."
    launchctl print "system/$label" >/dev/null ||
        die "Service is not loaded: $label. Load it before running this script."
    if [ -n "$labels" ]; then
        printf '%s' "$service" | jq -e '
            .ProgramArguments as $args |
            all(range(0; $args | length);
                if $args[.] == "--labels" then
                    ($args[. + 1] | type == "string" and length > 0 and (startswith("--") | not))
                else true end)
        ' >/dev/null || die "Malformed saved --labels argument in $plist"
    fi
done

log "Restarting ${count} runner(s) with ${memory_gib} GiB each; running jobs will be interrupted."
for ((i = 1; i <= count; i++)); do
    label="com.github.tart-runner-$i"
    plist="/Library/LaunchDaemons/$label.plist"
    log "Updating $label to ${memory_mb} MiB."
    plutil -replace EnvironmentVariables.TART_GUEST_MEMORY_MB -string "$memory_mb" "$plist"
    if [ -n "$labels" ]; then
        service="$(plutil -convert json -o - "$plist")"
        arguments="$(printf '%s' "$service" | jq -ce --arg labels "$labels" '
            .ProgramArguments as $args |
            [range(0; $args | length) |
                select($args[.] != "--labels" and (. == 0 or $args[. - 1] != "--labels")) |
                $args[.]] + ["--labels", $labels]
        ')"
        plutil -replace ProgramArguments -json "$arguments" "$plist"
    fi
    plutil -lint "$plist" >/dev/null
    launchctl bootout "system/$label"
    launchctl bootstrap system "$plist"
    launchctl print "system/$label" >/dev/null
done

image="$(printf '%s' "$shared_settings" | jq -r '.image')"
updater_args=(--launchd-user "$runner_user" --golden-image "$image")
if [ -n "$daily_at" ]; then updater_args+=(--daily-at "$daily_at"); fi
TART_UPDATE_MEMORY_MB=4096 \
    TART_RUNNER_CONFIG_DIR="$(printf '%s' "$shared_settings" | jq -r '.config')" \
    TART_SSH_KEY="$(printf '%s' "$shared_settings" | jq -r '.key')" \
    TART_GUEST_USER="$(printf '%s' "$shared_settings" | jq -r '.guest_user')" \
    TART_GUEST_RUNNER_DIR="$(printf '%s' "$shared_settings" | jq -r '.guest_runner')" \
    bash "$SCRIPT_DIR/tart-install-image-updater.sh" "${updater_args[@]}"
log "Configured ${count} runner(s) at ${memory_gib} GiB each and installed daily image updates at 4 GiB."
log "New job VMs use the allocation immediately after boot; verify with: tart get ${image}-runner-1"
