#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_ROOT TEST_LOG="$TEST_ROOT/commands.log"
export PATH="$TEST_ROOT/bin:$PATH"
mkdir -p "$TEST_ROOT/bin"

# Redirect only the policy's guest-owned paths. Every privileged command is mocked.
sed -e "s|/usr/local/libexec/tart-guest-memory|$TEST_ROOT/policy|g" \
    -e "s|/etc/systemd/system/tart-guest-memory.service|$TEST_ROOT/unit|g" \
    -e "s|/var/lib/tart-guest-memory|$TEST_ROOT/state|g" \
    -e "s|/run/tart-guest-memory.zram|$TEST_ROOT/runtime|g" \
    -e "s|/sys/block/zram0/disksize|$TEST_ROOT/zram-size|g" \
    -e "s|/sys/block/zram0/comp_algorithm|$TEST_ROOT/algorithm|g" \
    -e "s|/proc/meminfo|$TEST_ROOT/meminfo|g" \
    -e "s|/etc/systemd/zram-generator|$TEST_ROOT/etc/zram-generator|g" \
    -e "s|/usr/lib/systemd/zram-generator|$TEST_ROOT/lib/zram-generator|g" \
    "$SCRIPT_DIR/tart-guest-memory.sh" >"$TEST_ROOT/source"
payload="$(base64 <"$TEST_ROOT/source" | tr -d '\n')"
real_stat="$(command -v stat)"
export REAL_STAT="$real_stat"

cat >"$TEST_ROOT/bin/mock" <<'MOCK'
#!/bin/bash
set -euo pipefail
name="${0##*/}"
printf '%s' "$name" >> "$TEST_LOG"
printf ' <%s>' "$@" >> "$TEST_LOG"
printf '\n' >> "$TEST_LOG"
case "$name" in
    id) echo 0 ;;
    uname) echo Linux ;;
    getconf) echo 4096 ;;
    stat)
        case "$2" in
            '%u:%a') printf '0:%s\n' "$("$REAL_STAT" -c '%a' "$3")" ;;
            '%u:%h') printf '0:%s\n' "$("$REAL_STAT" -c '%h' "$3")" ;;
            '%s') echo "$TEST_DISK_SIZE" ;;
            *) "$REAL_STAT" "$@" ;;
        esac
        ;;
    systemctl)
        case "$1" in
            list-unit-files)
                if [ "$TEST_MANAGER" = 1 ]; then echo 'zramswap.service enabled'; fi
                ;;
            is-enabled)
                if [ "$3" = zramswap.service ]; then [ "$TEST_MANAGER" = 1 ]; else test -f "$TEST_ROOT/enabled"; fi
                ;;
            is-active)
                if [ "$3" = zramswap.service ]; then [ "$TEST_MANAGER" = 1 ]; else test -f "$TEST_ROOT/active"; fi
                ;;
            enable) touch "$TEST_ROOT/enabled" ;;
            start)
                bash "$TEST_ROOT/policy" activate
                touch "$TEST_ROOT/active"
                ;;
            daemon-reload) ;;
            *) echo "Unexpected systemctl: $*" >&2; exit 1 ;;
        esac
        ;;
    dd)
        [ "$TEST_DISK_FAIL" = 0 ] || { echo 'fixture disk full' >&2; exit 1; }
        # A tiny placeholder, not a real 12 GiB allocation.
        printf 'fixture' > "$TEST_ROOT/state/swapfile"
        ;;
    mkswap)
        [ "$TEST_MKSWAP_FAIL" = 0 ] || exit 1
        if [ "$1" != /dev/zram0 ]; then touch "$TEST_ROOT/signature"; fi
        ;;
    blkid)
        test -f "$TEST_ROOT/signature"
        echo swap
        ;;
    modprobe) ;;
    zramctl)
        if [ "$1" = --noheadings ]; then
            [ "$(cat "$TEST_ROOT/zram-size")" = 0 ] || echo /dev/zram0
        else
            [ "$1" = --algorithm ] && [ "$2" = zstd ] && [ "$3" = --size ]
            echo "$4" > "$TEST_ROOT/zram-size"
            echo '[zstd] lzo' > "$TEST_ROOT/algorithm"
        fi
        ;;
    swapon)
        if [ "$1" = --show=NAME,SIZE,PRIO ]; then
            [ "$TEST_SWAP_READ_FAIL" = 0 ] || exit 1
            cat "$TEST_ROOT/swaps"
        else
            [ "$1" = --priority ]
            [ "$TEST_SWAPON_FAIL" = 0 ] || exit 1
            bytes=12884901888
            if [ "$3" = /dev/zram0 ]; then bytes="$(cat "$TEST_ROOT/zram-size")"; fi
            printf '%s %s %s\n' "$3" "$((bytes - 4096))" "$2" >> "$TEST_ROOT/swaps"
        fi
        ;;
    *) echo "Unexpected privileged command: $name" >&2; exit 1 ;;
esac
MOCK
chmod +x "$TEST_ROOT/bin/mock"
for name in id uname getconf stat systemctl dd mkswap blkid modprobe zramctl swapon; do
    ln -s mock "$TEST_ROOT/bin/$name"
done

reset_case() {
    rm -rf "${TEST_ROOT:?}/state" "${TEST_ROOT:?}/etc" "${TEST_ROOT:?}/lib"
    rm -f "$TEST_ROOT/policy" "$TEST_ROOT/unit" "$TEST_ROOT/runtime" \
        "$TEST_ROOT/enabled" "$TEST_ROOT/active" "$TEST_ROOT/signature"
    : >"$TEST_LOG"
    : >"$TEST_ROOT/swaps"
    echo 0 >"$TEST_ROOT/zram-size"
    echo 'lzo [zstd]' >"$TEST_ROOT/algorithm"
    echo 'MemTotal: 6291456 kB' >"$TEST_ROOT/meminfo"
    export TEST_MANAGER=0 TEST_DISK_FAIL=0 TEST_SWAPON_FAIL=0 TEST_MKSWAP_FAIL=0
    export TEST_SWAP_READ_FAIL=0
    export TEST_DISK_SIZE=12884901888
}
apply_policy() {
    bash "$TEST_ROOT/source" install "$payload" >"$TEST_ROOT/result" 2>"$TEST_ROOT/output"
}
expect_failure() {
    if apply_policy; then
        echo 'FAIL: unsafe/failed policy accepted' >&2
        exit 1
    fi
}
assert_contains() {
    grep -Fq -- "$2" "$1" || {
        cat "$1"
        echo "FAIL: missing '$2'" >&2
        exit 1
    }
}

for memory_kib in 3145728 4194304 6291456 8388608 6291455; do
    reset_case
    printf 'MemTotal: %s kB\n' "$memory_kib" >"$TEST_ROOT/meminfo"
    apply_policy || {
        cat "$TEST_ROOT/output"
        exit 1
    }
    [ "$(cat "$TEST_ROOT/result")" = true ]
    expected=$((memory_kib * 1024 / 2 / 4096 * 4096))
    [ "$(cat "$TEST_ROOT/zram-size")" = "$expected" ]
    assert_contains "$TEST_ROOT/swaps" "/dev/zram0 $((expected - 4096)) 100"
    assert_contains "$TEST_ROOT/swaps" "$TEST_ROOT/state/swapfile 12884897792 10"
    apply_policy
    [ "$(cat "$TEST_ROOT/result")" = false ]
    [ "$(grep -c '^dd ' "$TEST_LOG")" = 1 ]
    assert_contains "$TEST_LOG" 'dd <if=/dev/zero>'
    assert_contains "$TEST_LOG" '<bs=1048576> <count=12288> <conv=notrunc,nocreat>'
    [ "$(grep -c '^mkswap ' "$TEST_LOG")" = 2 ]
    [ "$(wc -l <"$TEST_ROOT/swaps")" = 2 ]
    bash "$TEST_ROOT/policy" verify 2>"$TEST_ROOT/output"
done
echo 'PASS: actual guest RAM determines page-rounded 50% zram; 12 GiB disk is separate, priorities and repeat activation are verified'

# Simulate a reboot with a different maintenance RAM allocation and no /run state.
rm "$TEST_ROOT/runtime" "$TEST_ROOT/active"
echo 0 >"$TEST_ROOT/zram-size"
: >"$TEST_ROOT/swaps"
echo 'MemTotal: 4194304 kB' >"$TEST_ROOT/meminfo"
bash "$TEST_ROOT/policy" activate 2>"$TEST_ROOT/output"
[ "$(cat "$TEST_ROOT/zram-size")" = 2147483648 ]
[ "$(grep -c '^dd ' "$TEST_LOG")" = 1 ]
echo 'PASS: persisted policy reuses disk after reboot and resizes only fresh zram for maintenance RAM'

reset_case
export TEST_MANAGER=1
expect_failure
assert_contains "$TEST_ROOT/output" 'Conflicting zram manager'
[ ! -d "$TEST_ROOT/state" ]
reset_case
mkdir -p "$TEST_ROOT/etc"
touch "$TEST_ROOT/etc/zram-generator.conf"
expect_failure
assert_contains "$TEST_ROOT/output" 'Existing zram-generator configuration'
echo 'PASS: existing active/enabled managers and generator configurations fail without disabling them'

reset_case
echo 3221225472 >"$TEST_ROOT/zram-size"
printf '/dev/zram0 3221221376 5\n' >"$TEST_ROOT/swaps"
expect_failure
assert_contains "$TEST_ROOT/output" 'Unowned zram exists'
! grep -q '^mkswap </dev/zram0>' "$TEST_LOG"
reset_case
printf '/existing-swap 12345 5\n' >"$TEST_ROOT/swaps"
apply_policy
assert_contains "$TEST_ROOT/swaps" '/existing-swap 12345 5'
printf '/high-priority-swap 12345 100\n' >>"$TEST_ROOT/swaps"
expect_failure
assert_contains "$TEST_ROOT/output" 'Another swap has priority >= 100'
echo 'PASS: unknown zram is not reset; other swap is preserved and cannot outrank zram'

for failure in disk mkswap swapon read; do
    reset_case
    case "$failure" in
        disk) export TEST_DISK_FAIL=1 ;;
        mkswap) export TEST_MKSWAP_FAIL=1 ;;
        swapon) export TEST_SWAPON_FAIL=1 ;;
        read) export TEST_SWAP_READ_FAIL=1 ;;
    esac
    expect_failure
    [ -f "$TEST_ROOT/state/swapfile" ]
done
echo 'PASS: disk allocation, formatting and activation failures are fatal and preserve failed files'

reset_case
mkdir -m 700 "$TEST_ROOT/state"
printf 'unknown\n' >"$TEST_ROOT/state/swapfile"
expect_failure
assert_contains "$TEST_ROOT/state/swapfile" unknown
reset_case
ln -s "$TEST_ROOT/source" "$TEST_ROOT/policy"
expect_failure
assert_contains "$TEST_ROOT/output" 'Unsafe or unowned file'
echo 'PASS: unknown state and symlinked installation files cannot be overwritten'

reset_case
apply_policy
export TEST_DISK_SIZE=12345
expect_failure
assert_contains "$TEST_ROOT/output" 'Disk swap is not 12 GiB'
export TEST_DISK_SIZE=12884901888
sed -i 's/ 10$/ 20/' "$TEST_ROOT/swaps"
expect_failure
assert_contains "$TEST_ROOT/output" 'enabled size/priority mismatch'
echo 'PASS: verification detects wrong on-disk size and enabled priority rather than assuming success'
