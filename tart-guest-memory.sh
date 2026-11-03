#!/bin/bash
# tart-guest-memory-policy-v1
# Runs as root inside Linux guests, never on the macOS host.
set -euo pipefail

fail() {
    echo "[guest-memory] ERROR: $*" >&2
    exit 1
}
report() { echo "[guest-memory] $*" >&2; }

policy=/usr/local/libexec/tart-guest-memory
unit=/etc/systemd/system/tart-guest-memory.service
state=/var/lib/tart-guest-memory
swapfile="$state/swapfile"
runtime=/run/tart-guest-memory.zram
disk_bytes=12884901888
zram_priority=100
disk_priority=10

safe_file() {
    [ -f "$1" ] && [ ! -L "$1" ] &&
        [ "$(stat -c '%u:%h' "$1")" = 0:1 ] &&
        [ "$((8#$(stat -c '%a' "$1") & 0022))" -eq 0 ] ||
        fail "Unsafe or unowned file: $1"
}

check_managers() {
    local units name _status rest
    units="$(systemctl list-unit-files --no-legend --no-pager)"
    while read -r name _status rest; do
        case "$name" in
            tart-guest-memory.service) continue ;;
            *zram*.service | *zram*.swap)
                if systemctl is-active --quiet "$name" || systemctl is-enabled --quiet "$name"; then
                    fail "Conflicting zram manager: $name. Reconcile its configuration before retrying; it was not disabled."
                fi
                ;;
        esac
    done <<<"$units"
    local config
    for config in /etc/systemd/zram-generator.conf /usr/lib/systemd/zram-generator.conf \
        /etc/systemd/zram-generator.conf.d/*.conf /usr/lib/systemd/zram-generator.conf.d/*.conf; do
        [ ! -e "$config" ] && [ ! -L "$config" ] ||
            fail "Existing zram-generator configuration: $config. Reconcile it before retrying."
    done
}

read_sizes() {
    local memory_kib
    memory_kib="$(awk '$1 == "MemTotal:" && $3 == "kB" {print $2}' /proc/meminfo)"
    [[ "$memory_kib" =~ ^[1-9][0-9]*$ ]] || fail "Cannot read guest MemTotal in KiB."
    page_bytes="$(getconf PAGESIZE)"
    [[ "$page_bytes" =~ ^[1-9][0-9]*$ ]] || fail "Cannot read guest page size."
    zram_bytes=$((memory_kib * 1024 / 2 / page_bytes * page_bytes))
    [ "$zram_bytes" -gt "$page_bytes" ] || fail "Guest RAM is too small for zram."
    report "MemTotal=${memory_kib} KiB; zram=${zram_bytes} bytes (50%, page-rounded); disk=${disk_bytes} bytes (12 GiB)."
}

swap_entry() {
    local entries
    entries="$(swapon --show=NAME,SIZE,PRIO --bytes --noheadings --raw)" ||
        fail "Could not read enabled swap."
    awk -v name="$1" '$1 == name {print $2, $3}' <<<"$entries"
}

verify_swap() {
    local entry size priority
    entry="$(swap_entry "$1")"
    read -r size priority <<<"$entry"
    [ "$size" = "$(($2 - page_bytes))" ] && [ "$priority" = "$3" ] ||
        fail "$1 enabled size/priority mismatch: '${entry:-inactive}', expected $(($2 - page_bytes)) bytes at priority $3."
}

check_state() {
    [ -d "$state" ] && [ ! -L "$state" ] &&
        [ "$(stat -c '%u:%a' "$state")" = 0:700 ] ||
        fail "Unsafe state directory: $state"
    safe_file "$state/owner"
    grep -qx 'tart-guest-memory-policy-v1' "$state/owner" || fail "Unknown state owner."
}

check_disk() {
    safe_file "$swapfile"
    safe_file "$state/disk.identity"
    [ "$(stat -c '%d:%i' "$swapfile")" = "$(cat "$state/disk.identity")" ] ||
        fail "Disk swap identity changed; refusing to overwrite it."
    [ "$(stat -c '%s' "$swapfile")" = "$disk_bytes" ] || fail "Disk swap is not 12 GiB."
    [ "$(stat -c '%a' "$swapfile")" = 600 ] || fail "Disk swap must have mode 600."
    [ "$(blkid -p -s TYPE -o value "$swapfile")" = swap ] || fail "Disk file has no swap signature."
}

reconcile() {
    check_managers
    read_sizes
    if [ ! -e "$state" ] && [ ! -L "$state" ]; then
        mkdir -m 700 "$state"
        printf '%s\n' tart-guest-memory-policy-v1 >"$state/owner"
    fi
    check_state
    exec 9<"$state"
    flock --exclusive 9
    if [ ! -e "$swapfile" ] && [ ! -L "$swapfile" ]; then
        [ ! -e "$state/disk.identity" ] || fail "Owned disk swap is missing; investigate before recreating."
        report "Creating 12 GiB disk swap; allocation failures are fatal."
        (
            umask 077
            set -o noclobber
            : >"$swapfile"
        )
        dd if=/dev/zero of="$swapfile" bs=1048576 count=12288 conv=notrunc,nocreat status=none
        mkswap "$swapfile" >&2
        stat -c '%d:%i' "$swapfile" >"$state/disk.identity"
    fi
    check_disk
    if [ -z "$(swap_entry "$swapfile")" ]; then
        swapon --priority "$disk_priority" "$swapfile"
    fi
    verify_swap "$swapfile" "$disk_bytes" "$disk_priority"

    modprobe zram num_devices=1
    if [ -e "$runtime" ] || [ -L "$runtime" ]; then
        safe_file "$runtime"
        [ "$(cat "$runtime")" = /dev/zram0 ] || fail "Unknown zram runtime owner."
    else
        [ -z "$(zramctl --noheadings --raw --output NAME)" ] ||
            fail "Unowned zram exists; no device was reset or reformatted."
        [ "$(cat /sys/block/zram0/disksize)" = 0 ] || fail "Unowned /dev/zram0 has a configured size."
        printf '%s\n' /dev/zram0 >"$runtime"
    fi
    if [ "$(cat /sys/block/zram0/disksize)" = 0 ]; then
        zramctl --algorithm zstd --size "$zram_bytes" /dev/zram0
        mkswap /dev/zram0 >&2
    fi
    [ "$(cat /sys/block/zram0/disksize)" = "$zram_bytes" ] ||
        fail "Owned zram size differs from 50% of guest RAM; refusing a live reset."
    if [ -z "$(swap_entry /dev/zram0)" ]; then
        swapon --priority "$zram_priority" /dev/zram0
    fi
    verify
}

verify() {
    check_managers
    read_sizes
    check_state
    check_disk
    safe_file "$runtime"
    [ "$(cat "$runtime")" = /dev/zram0 ] || fail "Unknown zram runtime owner."
    [ "$(cat /sys/block/zram0/disksize)" = "$zram_bytes" ] || fail "Zram size mismatch."
    grep -q '\[zstd\]' /sys/block/zram0/comp_algorithm || fail "Zram is not using zstd."
    verify_swap /dev/zram0 "$zram_bytes" "$zram_priority"
    verify_swap "$swapfile" "$disk_bytes" "$disk_priority"
    local entries
    entries="$(swapon --show=NAME,SIZE,PRIO --bytes --noheadings --raw)" ||
        fail "Could not read enabled swap."
    if awk '$1 != "/dev/zram0" && $3 >= 100 {found=1} END {exit !found}' <<<"$entries"; then
        fail "Another swap has priority >= 100; zram must have the highest priority."
    fi
    report "Verified enabled swap (usable bytes exclude one metadata page):"
    printf '%s\n' "$entries" >&2
}

install_policy() (
    local payload="$1" work changed=false destination source mode pending=""
    check_managers
    work="$(mktemp -d)"
    trap 'rm -rf "$work"; if [ -n "$pending" ]; then rm -f "$pending"; fi' EXIT
    printf '%s' "$payload" | base64 -d >"$work/policy"
    grep -qx '# tart-guest-memory-policy-v1' "$work/policy" || fail "Invalid policy payload."
    cat >"$work/unit" <<'UNIT'
# tart-guest-memory-policy-v1
[Unit]
Description=Tart guest RAM-relative zram and disk swap
After=local-fs.target
Before=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/local/libexec/tart-guest-memory activate
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    for destination in "$policy" "$unit"; do
        source="$work/policy"
        mode=755
        if [ "$destination" = "$unit" ]; then
            source="$work/unit"
            mode=644
        fi
        if [ -e "$destination" ] || [ -L "$destination" ]; then
            safe_file "$destination"
            grep -qx '# tart-guest-memory-policy-v1' "$destination" ||
                fail "Refusing to overwrite unknown file: $destination"
            if cmp -s "$source" "$destination"; then continue; fi
        fi
        mkdir -p "$(dirname "$destination")"
        pending="$(mktemp "${destination}.XXXXXX")"
        install -m "$mode" "$source" "$pending"
        mv -f "$pending" "$destination"
        pending=""
        changed=true
    done
    if ! systemctl is-enabled --quiet tart-guest-memory.service; then changed=true; fi
    systemctl daemon-reload
    systemctl enable tart-guest-memory.service >&2
    # Do not restart a live swap device. The reconciler checks existing state.
    "$policy" activate >&2
    systemctl start tart-guest-memory.service >&2
    printf '%s\n' "$changed"
)

[ "$(id -u)" -eq 0 ] || fail "Root is required."
[ "$(uname -s)" = Linux ] || fail "Linux guests only."
umask 077
case "${1:-}" in
    install) install_policy "${2:?Missing policy payload}" ;;
    activate) reconcile ;;
    verify)
        systemctl is-enabled --quiet tart-guest-memory.service || fail "Boot service is not enabled."
        systemctl is-active --quiet tart-guest-memory.service || fail "Boot service is not active."
        verify
        ;;
    *) fail "Usage: tart-guest-memory {install <base64>|activate|verify}" ;;
esac
