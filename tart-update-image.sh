#!/bin/bash
# Update guest packages and the runner in a clone; publish after reboot validation.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/tart-common.sh"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --golden-image)
            TART_GOLDEN_IMAGE="${2:?Missing image name}"
            shift 2
            ;;
        -h | --help)
            echo "Usage: bash tart-update-image.sh [--golden-image <name>]"
            echo "Updates guest packages and the Actions runner; preserves the installed kernel."
            exit 0
            ;;
        *) die "Unknown argument: $1" ;;
    esac
done

for command_name in tart curl jq ssh; do
    require_cmd "$command_name"
done
[[ "$TART_GOLDEN_IMAGE" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Unsafe golden image name."
[[ "$TART_GUEST_RUNNER_DIR" =~ ^/[a-zA-Z0-9/._-]+$ ]] || die "Unsafe guest runner directory."

state_dir="${TART_CONFIG_DIR}/images"
mkdir -p "$state_dir"
lock_dir="${state_dir}/${TART_GOLDEN_IMAGE}.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
    die "Image refresh already locked: $lock_dir (check for a running refresh before removing a stale lock)."
fi

candidate=""
guest_ip=""
tart_pid=""
promoted=false
cleanup() {
    local exit_code=$?
    trap - EXIT
    if [ -n "$candidate" ]; then
        stop_guest "$candidate" "$guest_ip" || true
        if [ -n "$tart_pid" ]; then wait "$tart_pid" 2>/dev/null || true; fi
        if [ "$promoted" = false ]; then tart delete "$candidate" 2>/dev/null || true; fi
    fi
    rm -f "${state_dir}/${TART_GOLDEN_IMAGE}.current.tmp"
    rmdir "$lock_dir"
    if [ "$exit_code" -ne 0 ]; then err "Image refresh failed; current image was not replaced."; fi
    exit "$exit_code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

release="$(curl --fail --silent --show-error --location --connect-timeout 15 --max-time 120 \
    https://api.github.com/repos/actions/runner/releases/latest)"
version="$(printf '%s' "$release" | jq -er '.tag_name | ltrimstr("v")')"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid runner release version."
archive="actions-runner-linux-arm64-${version}.tar.gz"
digest="$(printf '%s' "$release" | jq -er --arg name "$archive" \
    '.assets[] | select(.name == $name) | .digest')"
[[ "$digest" =~ ^sha256:[a-f0-9]{64}$ ]] || die "Missing or invalid runner SHA-256 digest."
checksum="${digest#sha256:}"
url="https://github.com/actions/runner/releases/download/v${version}/${archive}"

source_image="$(current_runner_image)" || die "Invalid current image pointer."
candidate="${TART_GOLDEN_IMAGE}-runner-v${version}-$(date +%s)-$$"
log "Checking ${source_image} against runner ${version}; candidate ${candidate}"
tart clone "$source_image" "$candidate"
tart run --nested --no-graphics "$candidate" &
tart_pid=$!
guest_ip="$(tart_guest_ip "$candidate")"
[ -n "$guest_ip" ] || die "Candidate has no IP address."
wait_for_ssh "$guest_ip" || die "Candidate SSH did not become ready."
installed="$(ssh_guest "$guest_ip" "'${TART_GUEST_RUNNER_DIR}/bin/Runner.Listener' --version")"
original_kernel="$(ssh_guest "$guest_ip" 'uname -r')"
[ -n "$original_kernel" ] || die "Could not determine the current guest kernel."
upgrade_runner=false
[ "$installed" = "$version" ] || upgrade_runner=true

update_result="$(
    ssh_guest "$guest_ip" "sudo bash -s -- '$TART_GUEST_RUNNER_DIR' '$url' '$checksum' '$upgrade_runner'" <<'UPDATE'
set -euo pipefail
runner_dir="$1"
runner_url="$2"
checksum="$3"
upgrade_runner="$4"
[ ! -f "$runner_dir/.runner" ] || { echo "Refusing to update a registered image." >&2; exit 1; }
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
changed=false
update_guest() {
    local packages_before packages_after installed_packages package status owner
    packages_before="$(dpkg-query -W -f='${binary:Package}=${Version}\n')"
    installed_packages="$(dpkg-query -W -f='${binary:Package} ${db:Status-Status}\n')"
    while read -r package status; do
        if [[ "$package" == linux-* ]] && [ "$status" = installed ]; then
            apt-mark hold "$package"
        fi
    done <<< "$installed_packages"

    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=300 -o APT::Update::Error-Mode=any update
    apt-get -o DPkg::Lock::Timeout=300 -o Dpkg::Options::=--force-confold \
        --with-new-pkgs --no-remove -y upgrade

    if [ "$upgrade_runner" = true ]; then
        owner="$(stat -c '%u:%g' "$runner_dir")"
        curl --fail --location --connect-timeout 15 --max-time 600 "$runner_url" -o "$work_dir/runner.tar.gz"
        printf '%s  %s\n' "$checksum" "$work_dir/runner.tar.gz" | sha256sum --check -
        mkdir "$work_dir/runner"
        tar xzf "$work_dir/runner.tar.gz" -C "$work_dir/runner"
        "$work_dir/runner/bin/installdependencies.sh"
        chown -R "$owner" "$work_dir/runner"
        rm -rf "$runner_dir"
        mv "$work_dir/runner" "$runner_dir"
        changed=true
    fi

    packages_after="$(dpkg-query -W -f='${binary:Package}=${Version}\n')"
    [ "$packages_before" = "$packages_after" ] || changed=true
}
update_guest >&2
printf '%s\n' "$changed"
UPDATE
)"
case "$update_result" in
    true) ;;
    false)
        ssh_guest "$guest_ip" 'test -c /dev/kvm && kvm-ok'
        log "Runner ${version} and guest packages are current; no image promoted."
        exit 0
        ;;
    *) die "Invalid guest update result: $update_result" ;;
esac

stop_guest "$candidate" "$guest_ip"
wait "$tart_pid" 2>/dev/null || true
tart run --nested --no-graphics "$candidate" &
tart_pid=$!
guest_ip="$(tart_guest_ip "$candidate")"
[ -n "$guest_ip" ] || die "Rebooted candidate has no IP address."
wait_for_ssh "$guest_ip" || die "Rebooted candidate SSH did not become ready."
installed="$(ssh_guest "$guest_ip" "'${TART_GUEST_RUNNER_DIR}/bin/Runner.Listener' --version")"
[ "$installed" = "$version" ] || die "Candidate runner version mismatch: $installed"
updated_kernel="$(ssh_guest "$guest_ip" 'uname -r')"
[ "$updated_kernel" = "$original_kernel" ] || die "Candidate kernel changed: $original_kernel -> $updated_kernel"
ssh_guest "$guest_ip" 'test -c /dev/kvm && kvm-ok'
stop_guest "$candidate" "$guest_ip"
wait "$tart_pid" 2>/dev/null || true
tart_pid=""
guest_ip=""
printf '%s\n' "$candidate" >"${state_dir}/${TART_GOLDEN_IMAGE}.current.tmp"
mv "${state_dir}/${TART_GOLDEN_IMAGE}.current.tmp" "${state_dir}/${TART_GOLDEN_IMAGE}.current"
promoted=true
candidate=""
log "Promoted updated guest packages and runner ${version}; kernel ${original_kernel} preserved. Previous images retained for rollback."
