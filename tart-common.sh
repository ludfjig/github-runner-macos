#!/bin/bash
#
# tart-common.sh — Shared helpers for the Tart-based ephemeral GitHub Actions
# runners (Ubuntu guests with nested KVM on Apple Silicon).
#
# This file is meant to be *sourced*, not executed directly. It defines the
# default configuration, logging helpers, and SSH/Tart utility functions that
# the bake, loop, and bootstrap scripts share. Keeping these in one place
# avoids duplication and keeps the individual scripts focused.
#
# All defaults can be overridden via environment variables so the scripts can
# be reused across machines and repositories without editing source.

# Guard against direct execution — there is nothing to run here.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "tart-common.sh is a library and must be sourced, not executed." >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# Configuration (override via environment)
# -----------------------------------------------------------------------------

# Directory holding host-side state: the dedicated SSH keypair used to talk to
# the guests. Created on demand by the bake script.
TART_CONFIG_DIR="${TART_RUNNER_CONFIG_DIR:-$HOME/.config/github-runner-tart}"

# Dedicated SSH keypair for reaching the Tart guests. Generated once during the
# bake and reused afterwards. Never reuse a personal key here.
TART_SSH_KEY="${TART_SSH_KEY:-$TART_CONFIG_DIR/id_ed25519}"

# Default login on the cirruslabs Ubuntu image. These well-known credentials are
# only used *once* during the bake to inject our SSH key; password auth is then
# disabled inside the golden image. See the cirruslabs/tart documentation.
TART_GUEST_USER="${TART_GUEST_USER:-admin}"
TART_GUEST_PASSWORD="${TART_GUEST_PASSWORD:-admin}"

# Base OCI image and the name of the golden image we derive from it.
TART_BASE_IMAGE="${TART_BASE_IMAGE:-ghcr.io/cirruslabs/ubuntu:latest}"
TART_GOLDEN_IMAGE="${TART_GOLDEN_IMAGE:-gha-ubuntu-kvm}"

# Defaults target one job VM on a 16 GiB Mac; maintenance uses a smaller VM.
# Resource sizing is not a fix for the crashes in INCIDENT-tart-vm-crash.md.
TART_GUEST_CPUS="${TART_GUEST_CPUS:-2}"
TART_GUEST_MEMORY_MB="${TART_GUEST_MEMORY_MB:-8192}"
TART_UPDATE_MEMORY_MB="${TART_UPDATE_MEMORY_MB:-4096}"
TART_GUEST_DISK_GB="${TART_GUEST_DISK_GB:-50}"

validate_memory_mb() {
    [[ "$2" =~ ^[1-9][0-9]*$ ]] || die "$1 must be a positive integer in MiB."
}

# Where the GitHub Actions runner is installed inside the guest.
TART_GUEST_RUNNER_DIR="${TART_GUEST_RUNNER_DIR:-/opt/actions-runner}"

current_runner_image() {
    local image_file="${TART_CONFIG_DIR}/images/${TART_GOLDEN_IMAGE}.current"
    local image="$TART_GOLDEN_IMAGE"
    if [ -f "$image_file" ]; then
        IFS= read -r image < "$image_file" || return 1
    fi
    [[ "$image" =~ ^[a-zA-Z0-9._-]+$ ]] || return 1
    printf '%s\n' "$image"
}

# Locked callbacks share state_dir for selection, leases and retention records.
with_image_state_lock() (
    [[ "$TART_GOLDEN_IMAGE" =~ ^[a-zA-Z0-9._-]+$ ]] || {
        err "Unsafe golden image name."
        return 1
    }
    local state_dir="$TART_CONFIG_DIR/images"
    local selection_lock="$state_dir/$TART_GOLDEN_IMAGE.selection-lock"
    local attempts=0
    mkdir -p "$state_dir" || return 1
    until mkdir "$selection_lock" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge 30 ]; then
            err "Image selection is locked: $selection_lock; check for running maintenance before removing a stale lock."
            return 1
        fi
        sleep 1
    done
    trap 'rmdir "$selection_lock"' EXIT
    "$@"
)

managed_runner_image() {
    local image="$1" suffix
    [ "$image" != "$TART_GOLDEN_IMAGE" ] || return 0
    suffix="${image#"$TART_GOLDEN_IMAGE-runner-v"}"
    [ "$suffix" != "$image" ] &&
        [[ "$suffix" =~ ^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-[0-9]+$ ]]
}

list_local_runner_images() {
    local listing
    listing="$(tart list --source local --format json)" || {
        err "Could not list Tart images."
        return 1
    }
    printf '%s' "$listing" | jq -e 'type == "array" and all(.[];
        (.Name | type == "string") and (.State | type == "string") and
        (.Running | type == "boolean"))' >/dev/null || {
        err "Invalid Tart image list; refusing image maintenance."
        return 1
    }
    printf '%s\n' "$listing"
}

register_runner_images_locked() {
    local listing names image
    listing="$(list_local_runner_images)" || return 1
    names="$(printf '%s' "$listing" | jq -r '.[].Name')" || return 1
    mkdir -p "$state_dir/$TART_GOLDEN_IMAGE.managed" || return 1
    while IFS= read -r image; do
        if managed_runner_image "$image"; then
            touch "$state_dir/$TART_GOLDEN_IMAGE.managed/$image" || return 1
        fi
    done <<< "$names"
}

clone_runner_image_locked() {
    local clone="$1" image
    [[ "$clone" =~ ^[a-zA-Z0-9._-]+$ ]] || { err "Unsafe clone name: $clone"; return 1; }
    validate_memory_mb TART_GUEST_MEMORY_MB "$TART_GUEST_MEMORY_MB"
    image="$(current_runner_image)" || { err "Invalid current image pointer."; return 1; }
    mkdir -p "$state_dir/$TART_GOLDEN_IMAGE.in-use" || return 1
    printf '%s\n' "$image" > "$state_dir/$TART_GOLDEN_IMAGE.in-use/$clone" || return 1
    if ! tart clone "$image" "$clone" >&2; then
        err "Failed to clone runner image: $image"
        rm -f "$state_dir/$TART_GOLDEN_IMAGE.in-use/$clone"
        return 1
    fi
    if ! tart set "$clone" --memory "$TART_GUEST_MEMORY_MB" >&2; then
        err "Could not set job VM memory to ${TART_GUEST_MEMORY_MB} MiB: $clone"
        if tart delete "$clone" >&2; then
            rm -f "$state_dir/$TART_GOLDEN_IMAGE.in-use/$clone"
        else
            err "Could not delete clone after memory configuration failure; retaining its source lease."
        fi
        return 1
    fi
    printf '%s\n' "$image"
}

release_runner_image_locked() {
    local clone="$1"
    [[ "$clone" =~ ^[a-zA-Z0-9._-]+$ ]] || { err "Unsafe clone name: $clone"; return 1; }
    rm -f "$state_dir/$TART_GOLDEN_IMAGE.in-use/$clone"
}

select_runner_image_locked() {
    local image="$1"
    managed_runner_image "$image" || { err "Not a managed runner image: $image"; return 1; }
    tart get "$image" >/dev/null || return 1
    mkdir -p "$state_dir/$TART_GOLDEN_IMAGE.managed" || return 1
    touch "$state_dir/$TART_GOLDEN_IMAGE.managed/$image" || return 1
    printf '%s\n' "$image" > "$state_dir/$TART_GOLDEN_IMAGE.current.tmp" || return 1
    mv "$state_dir/$TART_GOLDEN_IMAGE.current.tmp" "$state_dir/$TART_GOLDEN_IMAGE.current"
}

reset_baked_image_state_locked() {
    rm -f "$state_dir/$TART_GOLDEN_IMAGE.successful/$TART_GOLDEN_IMAGE" \
        "$state_dir/$TART_GOLDEN_IMAGE.current"
}

prune_runner_images_locked() {
    local current listing image entry successful=false lkg="" rank best_rank=-1 lease in_use clones clone suffix fallback=""
    local image_pid best_pid=-1
    current="$(current_runner_image)" || { err "Invalid current image pointer; refusing cleanup."; return 1; }
    listing="$(list_local_runner_images)" || return 1
    for entry in "$state_dir/$TART_GOLDEN_IMAGE.managed/"*; do
        [ -f "$entry" ] || continue
        image="${entry##*/}"
        managed_runner_image "$image" || { err "Invalid managed image record: $image"; return 1; }
        [ -f "$state_dir/$TART_GOLDEN_IMAGE.successful/$image" ] || continue
        printf '%s' "$listing" | jq -e --arg image "$image" 'any(.[]; .Name == $image)' >/dev/null || continue
        successful=true
        [ "$image" != "$current" ] || continue
        rank=0
        image_pid=0
        if [ "$image" != "$TART_GOLDEN_IMAGE" ]; then
            rank="${image%-*}"
            rank="${rank##*-}"
            image_pid="${image##*-}"
        fi
        if [ "$rank" -gt "$best_rank" ] ||
            { [ "$rank" -eq "$best_rank" ] && [ "$image_pid" -gt "$best_pid" ]; }; then
            lkg="$image"
            best_rank="$rank"
            best_pid="$image_pid"
        fi
    done
    if [ -n "$lkg" ]; then
        printf '%s\n' "$lkg" > "$state_dir/$TART_GOLDEN_IMAGE.lkg.tmp" || return 1
        mv "$state_dir/$TART_GOLDEN_IMAGE.lkg.tmp" "$state_dir/$TART_GOLDEN_IMAGE.lkg" || return 1
    else
        rm -f "$state_dir/$TART_GOLDEN_IMAGE.lkg" || return 1
    fi
    if [ "$successful" = false ]; then
        fallback="$TART_GOLDEN_IMAGE"
        log "No job-proven LKG yet; retaining the original image as an unvalidated bootstrap fallback."
    fi
    clones="$(printf '%s' "$listing" | jq -r '.[].Name')" || return 1
    while IFS= read -r clone; do
        suffix="${clone#"$TART_GOLDEN_IMAGE-runner-"}"
        if [ "$suffix" != "$clone" ] && [[ "$suffix" =~ ^[0-9]+$ ]] &&
            [ ! -f "$state_dir/$TART_GOLDEN_IMAGE.in-use/$clone" ]; then
            log "Retaining images: clone $clone has no source lease; restart its old runner loop to enable safe cleanup."
            return 0
        fi
    done <<< "$clones"
    for entry in "$state_dir/$TART_GOLDEN_IMAGE.managed/"*; do
        [ -f "$entry" ] || continue
        image="${entry##*/}"
        [ "$image" != "$current" ] && [ "$image" != "$lkg" ] && [ "$image" != "$fallback" ] || continue
        in_use=false
        for lease in "$state_dir/$TART_GOLDEN_IMAGE.in-use/"*; do
            [ -f "$lease" ] || continue
            if grep -Fxq -- "$image" "$lease"; then in_use=true; break; fi
        done
        [ "$in_use" = false ] || continue
        printf '%s' "$listing" | jq -e --arg image "$image" \
            'any(.[]; .Name == $image and .State == "stopped" and .Running == false)' >/dev/null || continue
        log "Deleting superseded runner image: $image"
        tart delete "$image" || { err "Failed to delete superseded runner image: $image"; return 1; }
        rm -f "$entry" "$state_dir/$TART_GOLDEN_IMAGE.successful/$image" || return 1
    done
}

record_runner_image_success_locked() {
    local image="$1"
    managed_runner_image "$image" || { err "Not a managed runner image: $image"; return 1; }
    mkdir -p "$state_dir/$TART_GOLDEN_IMAGE.managed" "$state_dir/$TART_GOLDEN_IMAGE.successful" || return 1
    touch "$state_dir/$TART_GOLDEN_IMAGE.managed/$image" \
        "$state_dir/$TART_GOLDEN_IMAGE.successful/$image" || return 1
    log "Runner image completed a successful job: $image"
    prune_runner_images_locked
}

runner_job_succeeded() {
    LC_ALL=C grep -Eq $'^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z: Job .+ completed with result: Succeeded\r?$' "$1"
}

# Persistent host-side build cache, shared into each ephemeral guest over
# virtio-fs. The throwaway clones are destroyed after every job, but this
# directory lives on the host, so compiler/dependency caches (e.g. sccache)
# stay warm across jobs with zero network round-trips.
#
# CONCURRENCY: each runner index gets its OWN sub-directory (runner-<N>), so
# running multiple concurrent runners never shares one cache dir between two
# writers. This matters because sccache/cargo are not safe when several
# independent writers hit the same directory over virtio-fs at once — you'd risk
# corrupt cache entries. Per-runner dirs trade a little disk + cross-runner hit
# rate for correctness. Set TART_CACHE_DIR to relocate the cache root.
TART_CACHE_TAG="${TART_CACHE_TAG:-ci-cache}"
TART_CACHE_GUEST_MOUNT="${TART_CACHE_GUEST_MOUNT:-/var/cache/ci}"
TART_CACHE_MAX_SIZE="${TART_CACHE_MAX_SIZE:-20G}"
# Apple's Virtualization framework exposes ALL `tart run --dir` shares under one
# fixed virtio-fs "automount" tag; each named share (TART_CACHE_TAG) then appears
# as a sub-directory beneath the mountpoint. So the guest mounts THIS tag, and
# the actual cache lives at <mount>/<TART_CACHE_TAG>/.
TART_VIRTIOFS_AUTOMOUNT_TAG="${TART_VIRTIOFS_AUTOMOUNT_TAG:-com.apple.virtio-fs.automount}"

# Custom runner labels; GitHub also adds self-hosted, Linux, and ARM64.
# Do not reuse GitHub-hosted image labels: jobs match a subset of runner labels.
TART_RUNNER_LABELS="${TART_RUNNER_LABELS:-kvm}"

# How long (seconds) to wait for a guest to obtain an IP / accept SSH.
TART_BOOT_TIMEOUT="${TART_BOOT_TIMEOUT:-180}"

# Failure-throttling controls for runner loops. If too many iterations fail in
# a short window, loops can pause before retrying to avoid thrashing the host.
TART_FAILURE_WINDOW_SEC="${TART_FAILURE_WINDOW_SEC:-600}"
TART_FAILURE_THRESHOLD="${TART_FAILURE_THRESHOLD:-3}"
TART_FAILURE_COOLDOWN_SEC="${TART_FAILURE_COOLDOWN_SEC:-180}"

# Optional script-level debug tracing for loop scripts. Disabled by default.
# Set TART_RUNNER_DEBUG=1 to enable shell trace and ERR diagnostics.
TART_RUNNER_DEBUG="${TART_RUNNER_DEBUG:-0}"
TART_DEBUG_LOG_DIR="${TART_DEBUG_LOG_DIR:-$HOME/.github-runner-logs}"
TART_KEEP_FAILED_VM="${TART_KEEP_FAILED_VM:-0}"
TART_VM_LOG_LOOKBACK_MINUTES="${TART_VM_LOG_LOOKBACK_MINUTES:-10}"

# Common SSH options: ephemeral guests have throwaway host keys, so we skip
# host-key verification and never persist known_hosts entries.
TART_SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o LogLevel=ERROR
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o TCPKeepAlive=yes
)

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

err() {
    printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

# Abort with a message and non-zero status.
die() {
    err "$*"
    exit 1
}

# Ensure a required command is on PATH or abort.
require_cmd() {
    local cmd="$1"
    command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
}

# Enable bash xtrace into a dedicated file descriptor so normal stdout/stderr
# logs remain readable. Caller should pass a short per-runner label.
enable_debug_trace() {
    local trace_name="$1"

    [ "$TART_RUNNER_DEBUG" = "1" ] || return 0

    mkdir -p "$TART_DEBUG_LOG_DIR"
    TART_TRACE_LOG_FILE="${TART_DEBUG_LOG_DIR}/${trace_name}-trace.log"
    # shellcheck disable=SC2034
    PS4='+ [${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]-main}] '
    exec 9>>"$TART_TRACE_LOG_FILE"
    export BASH_XTRACEFD=9
    set -x
    log "Debug tracing enabled: ${TART_TRACE_LOG_FILE}"
}

# Install an ERR trap that records the exact failing command and line.
install_err_diagnostics() {
    local err_name="$1"
    local trap_cmd

    trap_cmd='exit_code=$?; err "['"${err_name}"'] Command failed (exit=${exit_code}) at ${BASH_SOURCE[0]}:${LINENO}: ${BASH_COMMAND}"; exit "${exit_code}"'
    trap "$trap_cmd" ERR
}

# Capture host-side diagnostics for Virtualization.framework and Tart around a
# failed iteration. This helps pinpoint VM crashes like VZErrorDomain Code=1.
capture_host_vm_diagnostics() {
    local runner_label="$1"
    local vm_name="$2"
    local report_dir latest_vm_report

    mkdir -p "$TART_DEBUG_LOG_DIR" || return 1
    local diag_file="${TART_DEBUG_LOG_DIR}/${runner_label}-vm-diagnostics.log"

    {
        echo ""
        echo "========== $(date '+%Y-%m-%d %H:%M:%S') =========="
        echo "runner=${runner_label} vm=${vm_name}"
        echo "macOS=$(sw_vers -productVersion 2>/dev/null || true) build=$(sw_vers -buildVersion 2>/dev/null || true)"
        echo "kernel=$(uname -a 2>/dev/null || true)"
        echo ""
        echo "-- tart list --"
        tart list 2>/dev/null || true
        echo ""
        echo "-- recent system log (Virtualization + tart) --"
        command log show --style compact --last "${TART_VM_LOG_LOOKBACK_MINUTES}m" \
            --predicate '(process == "tart") || (process == "ReportCrash") || (subsystem BEGINSWITH "com.apple.Virtualization") || (senderImagePath CONTAINS[c] "Virtualization")' \
            2>&1 | tail -n 300 || true

        for report_dir in "/Library/Logs/DiagnosticReports" "$HOME/Library/Logs/DiagnosticReports"; do
            [ -d "$report_dir" ] || continue
            echo ""
            echo "-- recent DiagnosticReports: ${report_dir} --"
            find "$report_dir" -maxdepth 1 -type f \
                \( -name 'tart*.crash' -o -name 'tart*.ips' -o -name '*Virtualization*.crash' -o -name '*Virtualization*.ips' -o -name 'kernel*.panic' -o -name 'kernel*.ips' \) \
                -print | tail -n 6 || true

            echo ""
            echo "-- latest available Virtualization crash report (candidate) --"
            latest_vm_report="$(find "$report_dir" -maxdepth 1 -type f -name 'com.apple.Virtualization.VirtualMachine-*.ips' | sort | tail -n 1)" || latest_vm_report=""
            if [ -n "$latest_vm_report" ] && [ -f "$latest_vm_report" ]; then
                echo "$latest_vm_report"
                cat "$latest_vm_report" || true
            else
                echo "none"
            fi
        done
        echo "-- end diagnostics --"
    } >> "$diag_file" 2>&1 || return 1

    err "[${runner_label}] Host VM diagnostics appended to ${diag_file}"
}

# -----------------------------------------------------------------------------
# Tart / SSH utility functions
# -----------------------------------------------------------------------------

# Resolve a running guest's IP address, waiting up to TART_BOOT_TIMEOUT seconds.
# Echoes the IP on success.
tart_guest_ip() {
    local vm="$1"
    tart ip "$vm" --wait "$TART_BOOT_TIMEOUT"
}

# Block until a TCP port starts accepting connections or the timeout elapses.
wait_for_tcp_port() {
    local host="$1"
    local port="$2"
    local deadline=$(( $(date +%s) + TART_BOOT_TIMEOUT ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ( : >"/dev/tcp/${host}/${port}" ) >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done

    return 1
}

# Block until the guest accepts a key-based SSH login or the timeout elapses.
wait_for_ssh() {
    local ip="$1"
    local deadline=$(( $(date +%s) + TART_BOOT_TIMEOUT ))

    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ssh -i "$TART_SSH_KEY" "${TART_SSH_OPTS[@]}" -o BatchMode=yes \
            "${TART_GUEST_USER}@${ip}" true 2>/dev/null; then
            return 0
        fi
        sleep 2
    done

    return 1
}

# Run a command in the guest using our dedicated key.
ssh_guest() {
    local ip="$1"
    shift
    ssh -i "$TART_SSH_KEY" "${TART_SSH_OPTS[@]}" -o BatchMode=yes \
        "${TART_GUEST_USER}@${ip}" "$@"
}

install_guest_memory_policy() {
    local ip="$1" payload
    payload="$(base64 < "$SCRIPT_DIR/tart-guest-memory.sh" | tr -d '\n')" || return 1
    ssh_guest "$ip" "sudo bash -s -- install '$payload'" < "$SCRIPT_DIR/tart-guest-memory.sh"
}

verify_guest_memory_policy() {
    ssh_guest "$1" 'sudo /usr/local/libexec/tart-guest-memory verify'
}

# Best-effort cleanup for detached `tart run ... <vm>` host processes.
# If the guest process crashes unexpectedly, these can survive and keep a VM
# appearing "running" even though the job loop has moved on.
kill_tart_run_processes() {
    local vm="$1"
    pkill -f "no-graphics ${vm}$" 2>/dev/null || true
}

# Best-effort graceful shutdown of a guest, falling back to `tart stop`.
stop_guest() {
    local vm="$1"
    local ip="$2"

    if [ -n "$ip" ]; then
        ssh_guest "$ip" "sudo shutdown -h now" 2>/dev/null || true
    fi

    # Give the guest a short grace period to power off on its own, then force.
    local deadline=$(( $(date +%s) + 30 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if ! tart list 2>/dev/null | grep -qE "[[:space:]]${vm}[[:space:]].*running"; then
            kill_tart_run_processes "$vm"
            return 0
        fi
        sleep 2
    done

    tart stop "$vm" 2>/dev/null || true
    kill_tart_run_processes "$vm"
}
