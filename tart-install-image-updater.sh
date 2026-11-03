#!/bin/bash
# Install daily image maintenance without reconfiguring runner services.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CUSTOM_SSH_KEY="${TART_SSH_KEY:-}"
source "$SCRIPT_DIR/tart-common.sh"

LAUNCHD_SCOPE=daemon
LAUNCHD_USER="${SUDO_USER:-$USER}"
LAUNCHD_DIR=""
LAUNCHD_LABEL_PREFIX=com.github.tart-runner
DAILY_AT=""

usage() {
    cat <<'USAGE'
Usage: sudo bash tart-install-image-updater.sh [options]

  --launchd-user <user>       Tart owner. Default: invoking user, including sudo.
  --launchd-scope <scope>     daemon (default, starts at boot) or agent (login required).
  --golden-image <name>       Default: gha-ubuntu-kvm.
  --launchd-label-prefix <p>  Default: com.github.tart-runner.
  --launchd-dir <path>        Override the scope's standard service directory.
  --daily-at <HH:MM>         Daily local time (e.g. 03:00), no run at load.

Installs the checker to run immediately and every 24 hours. Does not restart
runner services, bake an image, or require GitHub App credentials.
Each check updates guest APT packages and the runner, preserving the kernel.
Maintenance VM RAM: TART_UPDATE_MEMORY_MB (default 4096 MiB).
USAGE
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --launchd-user)
            LAUNCHD_USER="${2:?Missing user}"
            shift 2
            ;;
        --launchd-scope)
            LAUNCHD_SCOPE="${2:?Missing scope}"
            shift 2
            ;;
        --golden-image)
            TART_GOLDEN_IMAGE="${2:?Missing image}"
            shift 2
            ;;
        --launchd-label-prefix)
            LAUNCHD_LABEL_PREFIX="${2:?Missing label prefix}"
            shift 2
            ;;
        --launchd-dir)
            LAUNCHD_DIR="${2:?Missing directory}"
            shift 2
            ;;
        --daily-at)
            DAILY_AT="${2:?Missing HH:MM}"
            [[ "$DAILY_AT" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] ||
                die "--daily-at requires HH:MM (00:00..23:59)."
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

for command_name in tart jq launchctl plutil; do
    require_cmd "$command_name"
done
[[ "$TART_GOLDEN_IMAGE" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Unsafe golden image name."
[[ "$LAUNCHD_LABEL_PREFIX" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Unsafe label prefix."
validate_memory_mb TART_UPDATE_MEMORY_MB "$TART_UPDATE_MEMORY_MB"
case "$LAUNCHD_SCOPE" in
    daemon)
        [ "$(id -u)" -eq 0 ] || die "Daemon installation requires sudo."
        [ -n "$LAUNCHD_USER" ] && [ "$LAUNCHD_USER" != root ] || die "Choose the non-root Tart owner with --launchd-user."
        RUNNER_HOME="$(dscl . -read "/Users/${LAUNCHD_USER}" NFSHomeDirectory | awk '{print $2}')"
        [ -n "$RUNNER_HOME" ] || die "Could not resolve the Tart owner's home."
        [ -n "$LAUNCHD_DIR" ] || LAUNCHD_DIR=/Library/LaunchDaemons
        ;;
    agent)
        RUNNER_HOME="$HOME"
        [ -n "$LAUNCHD_DIR" ] || LAUNCHD_DIR="$HOME/Library/LaunchAgents"
        ;;
    *) die "--launchd-scope must be agent or daemon." ;;
esac

CONFIG_DIR_VALUE="${TART_RUNNER_CONFIG_DIR:-$RUNNER_HOME/.config/github-runner-tart}"
TART_SSH_KEY="${CUSTOM_SSH_KEY:-$CONFIG_DIR_VALUE/id_ed25519}"
label="${LAUNCHD_LABEL_PREFIX}-image-refresh"
plist_dest="${LAUNCHD_DIR}/${label}.plist"
[ ! -L "$plist_dest" ] && { [ ! -e "$plist_dest" ] || [ -f "$plist_dest" ]; } ||
    die "Unsafe updater service file: $plist_dest"
log_dir="${RUNNER_HOME}/.github-runner-logs"
mkdir -p "$LAUNCHD_DIR" "$log_dir" "$CONFIG_DIR_VALUE/images"
if [ "$LAUNCHD_SCOPE" = daemon ]; then
    chown "$LAUNCHD_USER" "$log_dir" "$CONFIG_DIR_VALUE" "$CONFIG_DIR_VALUE/images"
    launchctl bootout "system/${label}" >/dev/null 2>&1 || true
else
    launchctl unload "$plist_dest" >/dev/null 2>&1 || true
fi

arguments="$(jq -cn --arg script "$SCRIPT_DIR/tart-update-image.sh" \
    --arg image "$TART_GOLDEN_IMAGE" \
    '["/usr/bin/caffeinate", "-is", "/bin/bash", $script, "--golden-image", $image]')"
environment="$(jq -cn --arg home "$RUNNER_HOME" --arg config "$CONFIG_DIR_VALUE" \
    --arg key "$TART_SSH_KEY" --arg user "$TART_GUEST_USER" --arg runner "$TART_GUEST_RUNNER_DIR" \
    --arg memory "$TART_UPDATE_MEMORY_MB" \
    '{HOME: $home, PATH: "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      TART_RUNNER_CONFIG_DIR: $config, TART_SSH_KEY: $key,
      TART_GUEST_USER: $user, TART_GUEST_RUNNER_DIR: $runner,
      TART_UPDATE_MEMORY_MB: $memory}')"
plutil -create xml1 "$plist_dest"
plutil -insert Label -string "$label" "$plist_dest"
plutil -insert ProgramArguments -json "$arguments" "$plist_dest"
plutil -insert EnvironmentVariables -json "$environment" "$plist_dest"
if [ -n "$DAILY_AT" ]; then
    hour="${DAILY_AT%:*}"
    minute="${DAILY_AT#*:}"
    calendar="$(jq -cn --argjson hour "$((10#$hour))" --argjson minute "$((10#$minute))" \
        '{Hour: $hour, Minute: $minute}')"
    plutil -insert RunAtLoad -bool NO "$plist_dest"
    plutil -insert StartCalendarInterval -json "$calendar" "$plist_dest"
else
    plutil -insert RunAtLoad -bool YES "$plist_dest"
    plutil -insert StartInterval -integer 86400 "$plist_dest"
fi
plutil -insert StandardOutPath -string "$log_dir/tart-image-refresh-stdout.log" "$plist_dest"
plutil -insert StandardErrorPath -string "$log_dir/tart-image-refresh-stderr.log" "$plist_dest"
plutil -insert WorkingDirectory -string "$SCRIPT_DIR" "$plist_dest"
if [ "$LAUNCHD_SCOPE" = daemon ]; then
    plutil -insert UserName -string "$LAUNCHD_USER" "$plist_dest"
fi
plutil -lint "$plist_dest"
chmod 644 "$plist_dest"
if [ "$LAUNCHD_SCOPE" = daemon ]; then
    launchctl bootstrap system "$plist_dest"
    launchctl enable "system/${label}"
else
    launchctl load "$plist_dest"
fi
if [ -n "$DAILY_AT" ]; then
    log "Daily image checker installed: $label at $DAILY_AT local time (no run at load)."
else
    log "Daily image checker installed: $label (also runs at load)."
fi
log "Scheduling does not prevent overlap with running jobs."
