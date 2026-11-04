#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_ROOT
mkdir -p "$TEST_ROOT/bin"
export PATH="$TEST_ROOT/bin:$PATH"
export TART_RUNNER_CONFIG_DIR="$TEST_ROOT/config"
export TEST_LOG="$TEST_ROOT/commands.log"
export TEST_INSTALLED=2.336.0 TEST_EXPECTED=2.338.2
export TEST_FAIL_UPDATE=0 TEST_FAIL_KVM=0 TEST_FAIL_DIGEST=0
export TEST_PACKAGE_UPDATE=1 TEST_FAIL_PACKAGES=0 TEST_FAIL_KERNEL=0 TEST_CORRUPT_ARCHIVE=0
export TEST_FAIL_PRUNE=0
export TART_UPDATE_MEMORY_MB=4096 TEST_IMAGE_MEMORY=8192
export TEST_FAIL_SET_MEMORY="" TEST_BAD_MEMORY_CONFIG=0
export TEST_POLICY_CHANGED=false TEST_POLICY_FAIL=0 TEST_POLICY_VERIFY_FAIL=0
export TEST_ARCHIVE="$TEST_ROOT/runner.tar.gz"
mkdir -p "$TEST_ROOT/archive/bin" "$TEST_ROOT/guest-template/bin"
cat >"$TEST_ROOT/archive/bin/Runner.Listener" <<'LISTENER'
#!/bin/bash
echo "$TEST_EXPECTED"
LISTENER
cat >"$TEST_ROOT/archive/bin/installdependencies.sh" <<'DEPENDENCIES'
#!/bin/bash
echo 'runner dependencies installed'
DEPENDENCIES
chmod +x "$TEST_ROOT/archive/bin/"*
tar czf "$TEST_ARCHIVE" -C "$TEST_ROOT/archive" .
cat >"$TEST_ROOT/guest-template/bin/Runner.Listener" <<'INSTALLED'
#!/bin/bash
echo "$TEST_INSTALLED"
INSTALLED
chmod +x "$TEST_ROOT/guest-template/bin/Runner.Listener"

cat >"$TEST_ROOT/bin/mock" <<'MOCK'
#!/bin/bash
set -euo pipefail
command_name="${0##*/}"
printf '%s' "$command_name" >> "$TEST_LOG"
printf ' <%s>' "$@" >> "$TEST_LOG"
printf '\n' >> "$TEST_LOG"
case "$command_name" in
    curl)
        if [[ "${*: -1}" == */releases/latest ]]; then
            checksum="$(sha256sum "$TEST_ARCHIVE")"
            digest="sha256:${checksum%% *}"
            [ "$TEST_FAIL_DIGEST" = 0 ] || digest=null
            jq -n --arg version "$TEST_EXPECTED" --arg digest "$digest" \
                '{tag_name: ("v" + $version), assets: [{name: ("actions-runner-linux-arm64-" + $version + ".tar.gz"), digest: $digest}]}'
        else
            output="${*: -1}"
            cp "$TEST_ARCHIVE" "$output"
            if [ "$TEST_CORRUPT_ARCHIVE" = 1 ]; then printf 'corrupt' >> "$output"; fi
        fi
        ;;
    tart)
        case "$1" in
            clone)
                rm -rf "$TEST_ROOT/guest"
                cp -R "$TEST_ROOT/guest-template" "$TEST_ROOT/guest"
                rm -f "$TEST_ROOT/updated" "$TEST_ROOT/packages-upgraded"
                printf '%s\n' "$TEST_IMAGE_MEMORY" > "$TEST_ROOT/guest-memory"
                ;;
            get)
                if [[ "$*" == *'--format json'* ]]; then
                    if [ "$TEST_BAD_MEMORY_CONFIG" = 1 ]; then
                        echo '{"Memory":"invalid"}'
                    else
                        jq -n --argjson memory "$(cat "$TEST_ROOT/guest-memory")" '{Memory: $memory}'
                    fi
                fi
                ;;
            set)
                [ "$3" = --memory ]
                [ "$4" != "$TEST_FAIL_SET_MEMORY" ] || exit 1
                printf '%s\n' "$4" > "$TEST_ROOT/guest-memory"
                ;;
            run)
                memory="$(cat "$TEST_ROOT/guest-memory")"
                [ "$memory" = "$TART_UPDATE_MEMORY_MB" ]
                printf 'maintenance-boot-memory <%s>\n' "$memory" >> "$TEST_LOG"
                ;;
            ip) echo 192.0.2.1 ;;
            list)
                if [[ "$*" == *'--format json'* ]]; then
                    if [ "$TEST_FAIL_PRUNE" = 1 ] && [ -f "$TEST_ROOT/updated" ]; then
                        echo '{}'
                    else
                        echo '[{"Name":"gha-ubuntu-kvm","State":"stopped","Running":false}]'
                    fi
                else
                    echo 'local gha-ubuntu-kvm stopped'
                fi
                ;;
        esac
        ;;
    ssh)
        case "${*: -1}" in
            *'sudo bash -s -- install '*)
                cat > "$TEST_ROOT/guest-policy.sh"
                [ "$TEST_POLICY_FAIL" = 0 ] || exit 1
                printf '%s\n' "$TEST_POLICY_CHANGED"
                ;;
            'sudo /usr/local/libexec/tart-guest-memory verify')
                [ "$TEST_POLICY_VERIFY_FAIL" = 0 ] || exit 1
                ;;
            *"test ! -f "*)
                [ ! -f "$TEST_ROOT/guest/.runner" ]
                ;;
            *'--version')
                "$TEST_ROOT/guest/bin/Runner.Listener" --version
                ;;
            *'sudo bash -s'*)
                cat > "$TEST_ROOT/guest-update.sh"
                [ "$TEST_FAIL_UPDATE" = 0 ] || exit 1
                read -r -a guest_arguments <<< "${*: -1}"
                runner_url="${guest_arguments[5]//\'/}"
                checksum="${guest_arguments[6]//\'/}"
                upgrade_runner="${guest_arguments[7]//\'/}"
                bash "$TEST_ROOT/guest-update.sh" "$TEST_ROOT/guest" "$runner_url" "$checksum" "$upgrade_runner"
                touch "$TEST_ROOT/updated"
                ;;
            'uname -r')
                if [ "$TEST_FAIL_KERNEL" = 1 ] && [ -f "$TEST_ROOT/updated" ]; then
                    echo 7.0.0-wrong
                else
                    echo 7.0.0-28-vmid5
                fi
                ;;
            *kvm-ok*) [ "$TEST_FAIL_KVM" = 0 ] ;;
        esac
        ;;
    pkill) exit 0 ;;
    openssl) exit 0 ;;
    dscl) echo "NFSHomeDirectory: $HOME" ;;
    id) echo 0 ;;
    chown) exit 0 ;;
    stat)
        [ "$1" = -c ] && [ "$2" = '%u:%g' ]
        echo 1000:1000
        ;;
    apt-get)
        if [[ " $* " == *' upgrade '* ]]; then
            [ "$TEST_FAIL_PACKAGES" = 0 ] || exit 1
            [ "$TEST_PACKAGE_UPDATE" = 0 ] || touch "$TEST_ROOT/packages-upgraded"
        fi
        ;;
    apt-mark) exit 0 ;;
    dpkg-query)
        if [[ "$*" == *'Status-Status'* ]]; then
            printf 'linux-image-7.0.0-28-vmid5 installed\nlinux-headers-7.0.0-28-vmid5 installed\ncurl installed\n'
        elif [ -f "$TEST_ROOT/packages-upgraded" ]; then
            printf 'curl=2\nlinux-image-7.0.0-28-vmid5=1\n'
        else
            printf 'curl=1\nlinux-image-7.0.0-28-vmid5=1\n'
        fi
        ;;
    plutil)
        python3 - "$@" <<'PLIST'
import json
import plistlib
import sys

operation, *arguments = sys.argv[1:]
path = arguments[-1]
if operation == "-create":
    value = {}
else:
    with open(path, "rb") as stream:
        value = plistlib.load(stream)
    if operation == "-lint":
        sys.exit(0)
    key, kind, raw, _ = arguments
    assert key not in value
    parsers = {"-json": json.loads, "-integer": int, "-bool": lambda text: text == "YES", "-string": str}
    value[key] = parsers[kind](raw)
with open(path, "wb") as stream:
    plistlib.dump(value, stream)
PLIST
        ;;
    launchctl)
        if [ "$1" = list ]; then exit 1; fi
        ;;
esac
MOCK
chmod +x "$TEST_ROOT/bin/mock"
for command_name in curl tart ssh pkill openssl dscl id chown stat plutil launchctl defaults apt-get apt-mark dpkg-query; do
    ln -s mock "$TEST_ROOT/bin/$command_name"
done

assert_contains() {
    if ! grep -Fq -- "$2" "$1"; then
        echo "FAIL: missing '$2' in $1" >&2
        exit 1
    fi
}

run_refresh() {
    bash "$SCRIPT_DIR/tart-update-image.sh"
}

run_refresh
pointer="$TART_RUNNER_CONFIG_DIR/images/gha-ubuntu-kvm.current"
[ -f "$pointer" ]
promoted="$(cat "$pointer")"
[[ "$promoted" == gha-ubuntu-kvm-runner-v2.338.2-* ]]
assert_contains "$TEST_LOG" '<test -c /dev/kvm && kvm-ok>'
assert_contains "$TEST_ROOT/guest-update.sh" 'sha256sum --check'
assert_contains "$TEST_LOG" 'apt-mark <hold> <linux-image-7.0.0-28-vmid5>'
assert_contains "$TEST_LOG" 'apt-mark <hold> <linux-headers-7.0.0-28-vmid5>'
assert_contains "$TEST_LOG" '<--with-new-pkgs> <--no-remove> <-y> <upgrade>'
[ "$(grep -c '^maintenance-boot-memory <4096>$' "$TEST_LOG")" -eq 2 ]
[ "$(cat "$TEST_ROOT/guest-memory")" = 8192 ]
assert_contains "$TEST_LOG" '<--memory> <4096>'
assert_contains "$TEST_LOG" '<--memory> <8192>'
bash -n "$TEST_ROOT/guest-update.sh"
shellcheck --shell=bash -S warning "$TEST_ROOT/guest-update.sh"
export TART_GOLDEN_IMAGE=gha-ubuntu-kvm
source "$SCRIPT_DIR/tart-common.sh"
[ "$(current_runner_image)" = "$promoted" ]
echo 'PASS: guest payload executes package upgrade, kernel holds and verified runner installation'

: >"$TEST_LOG"
rm "$TEST_ROOT/updated"
export TEST_FAIL_PRUNE=1
if run_refresh >"$TEST_ROOT/prune-failure-output" 2>&1; then
    echo 'FAIL: post-promotion cleanup failure reported success'
    exit 1
fi
promoted="$(cat "$pointer")"
assert_contains "$TEST_ROOT/prune-failure-output" 'Image was promoted, but image maintenance failed'
if grep -Fq 'current image was not replaced' "$TEST_ROOT/prune-failure-output" ||
    grep -Fq "tart <delete> <$promoted>" "$TEST_LOG"; then
    echo 'FAIL: cleanup failure misreported or removed the promoted image'
    exit 1
fi
[ ! -d "$TART_RUNNER_CONFIG_DIR/images/gha-ubuntu-kvm.lock" ]
[ ! -d "$TART_RUNNER_CONFIG_DIR/images/gha-ubuntu-kvm.selection-lock" ]
export TEST_FAIL_PRUNE=0
echo 'PASS: cleanup failure returns non-zero without reverting or deleting a promoted image'

: >"$TEST_LOG"
export TART_UPDATE_MEMORY_MB=2048 TEST_IMAGE_MEMORY=6144
run_refresh
promoted="$(cat "$pointer")"
[ "$(grep -c '^maintenance-boot-memory <2048>$' "$TEST_LOG")" -eq 2 ]
[ "$(cat "$TEST_ROOT/guest-memory")" = 6144 ]
export TART_UPDATE_MEMORY_MB=4096 TEST_IMAGE_MEMORY=8192
echo 'PASS: both maintenance boots use the independent budget and publication restores source image memory'

for fail_memory in 4096 8192; do
    : >"$TEST_LOG"
    export TEST_FAIL_SET_MEMORY="$fail_memory"
    if run_refresh >"$TEST_ROOT/memory-failure-output" 2>&1; then
        echo 'FAIL: memory configuration failure accepted'
        exit 1
    fi
    [ "$(cat "$pointer")" = "$promoted" ]
    assert_contains "$TEST_ROOT/memory-failure-output" 'current image was not replaced'
    if [ "$fail_memory" = 4096 ]; then
        ! grep -q '^maintenance-boot-memory' "$TEST_LOG"
    fi
done
export TEST_FAIL_SET_MEMORY=""
: >"$TEST_LOG"
export TEST_BAD_MEMORY_CONFIG=1
if run_refresh >"$TEST_ROOT/memory-failure-output" 2>&1; then exit 1; fi
assert_contains "$TEST_ROOT/memory-failure-output" 'Could not read the candidate image memory allocation'
[ "$(cat "$pointer")" = "$promoted" ]
! grep -q '^maintenance-boot-memory' "$TEST_LOG"
export TEST_BAD_MEMORY_CONFIG=0
: >"$TEST_LOG"
if TART_UPDATE_MEMORY_MB=invalid run_refresh >"$TEST_ROOT/memory-failure-output" 2>&1; then exit 1; fi
assert_contains "$TEST_ROOT/memory-failure-output" 'TART_UPDATE_MEMORY_MB must be a positive integer in MiB'
! grep -q '^tart <clone>' "$TEST_LOG"
echo 'PASS: invalid budgets, unreadable memory metadata and failed resize/restore operations prevent publication'

: >"$TEST_LOG"
rm -f "$TEST_ROOT/updated"
export TEST_INSTALLED="$TEST_EXPECTED"
run_refresh
assert_contains "$TEST_LOG" "clone> <$promoted>"
promoted="$(cat "$pointer")"
assert_contains "$TEST_LOG" '<--with-new-pkgs> <--no-remove> <-y> <upgrade>'
if grep -Fq 'curl <--fail> <--location>' "$TEST_LOG"; then exit 1; fi
echo 'PASS: current runner still receives package-only updates without a runner download'

: >"$TEST_LOG"
export TEST_PACKAGE_UPDATE=0
run_refresh
[ "$(cat "$pointer")" = "$promoted" ]
assert_contains "$TEST_LOG" 'tart <delete>'
echo 'PASS: no package or runner changes means no image promotion'

: >"$TEST_LOG"
export TEST_POLICY_CHANGED=true
run_refresh
promoted="$(cat "$pointer")"
[ "$(grep -c '^maintenance-boot-memory <4096>$' "$TEST_LOG")" -eq 2 ]
assert_contains "$TEST_LOG" '<sudo /usr/local/libexec/tart-guest-memory verify>'
echo 'PASS: policy-only migration promotes after reboot even with unchanged packages and runner'

for failure in install verify; do
    export TEST_POLICY_FAIL=0 TEST_POLICY_VERIFY_FAIL=0
    if [ "$failure" = install ]; then export TEST_POLICY_FAIL=1; else export TEST_POLICY_VERIFY_FAIL=1; fi
    if run_refresh >"$TEST_ROOT/policy-failure-output" 2>&1; then
        echo "FAIL: policy $failure failure accepted"
        exit 1
    fi
    [ "$(cat "$pointer")" = "$promoted" ]
done
export TEST_POLICY_CHANGED=false TEST_POLICY_FAIL=0 TEST_POLICY_VERIFY_FAIL=0
echo 'PASS: policy installation and reboot verification failures preserve the selected image'

export TEST_PACKAGE_UPDATE=1 TEST_FAIL_PACKAGES=1
if run_refresh; then
    echo 'FAIL: package failure accepted'
    exit 1
fi
[ "$(cat "$pointer")" = "$promoted" ]
export TEST_FAIL_PACKAGES=0 TEST_FAIL_KERNEL=1
if run_refresh; then
    echo 'FAIL: kernel change accepted'
    exit 1
fi
[ "$(cat "$pointer")" = "$promoted" ]
export TEST_FAIL_KERNEL=0
echo 'PASS: package failure or changed boot kernel preserves selected image'

export TEST_INSTALLED=2.336.0 TEST_CORRUPT_ARCHIVE=1
if run_refresh; then
    echo 'FAIL: corrupt download accepted'
    exit 1
fi
[ "$(cat "$pointer")" = "$promoted" ]
export TEST_CORRUPT_ARCHIVE=0
echo 'PASS: actual archive checksum failure prevents promotion'

touch "$TEST_ROOT/guest-template/.runner"
: >"$TEST_LOG"
if run_refresh; then
    echo 'FAIL: registered image accepted'
    exit 1
fi
[ "$(cat "$pointer")" = "$promoted" ]
if grep -Fq 'apt-get ' "$TEST_LOG"; then exit 1; fi
rm "$TEST_ROOT/guest-template/.runner"
echo 'PASS: registered images are rejected before package maintenance'

export TEST_INSTALLED=2.336.0 TEST_FAIL_UPDATE=1
if run_refresh; then
    echo 'FAIL: update failure accepted'
    exit 1
fi
[ "$(cat "$pointer")" = "$promoted" ]
[ ! -d "$TART_RUNNER_CONFIG_DIR/images/gha-ubuntu-kvm.lock" ]
echo 'PASS: failed update preserves pointer and releases lock'

export TEST_FAIL_UPDATE=0 TEST_FAIL_KVM=1
if run_refresh; then
    echo 'FAIL: KVM failure accepted'
    exit 1
fi
[ "$(cat "$pointer")" = "$promoted" ]
echo 'PASS: failed reboot validation preserves pointer'

export TEST_FAIL_KVM=0 TEST_FAIL_DIGEST=1
: >"$TEST_LOG"
if run_refresh; then
    echo 'FAIL: invalid digest accepted'
    exit 1
fi
if grep -Fq 'tart <clone>' "$TEST_LOG"; then exit 1; fi
echo 'PASS: invalid checksum metadata rejected before cloning'

mkdir "$TART_RUNNER_CONFIG_DIR/images/gha-ubuntu-kvm.lock"
if run_refresh; then
    echo 'FAIL: concurrent refresh accepted'
    exit 1
fi
rmdir "$TART_RUNNER_CONFIG_DIR/images/gha-ubuntu-kvm.lock"
echo 'PASS: concurrent refresh rejected'

printf 'invalid/image\n' >"$pointer"
if current_runner_image; then
    echo 'FAIL: invalid pointer accepted'
    exit 1
fi
rm "$pointer"
[ "$(current_runner_image)" = gha-ubuntu-kvm ]
echo 'PASS: missing pointer falls back; malformed pointer fails closed'

export HOME="$TEST_ROOT/home" USER=test-user
mkdir -p "$HOME"
touch "$TEST_ROOT/app.pem"
: >"$TEST_LOG"
bash "$SCRIPT_DIR/tart-install-image-updater.sh" --launchd-user test-user \
    --launchd-dir "$TEST_ROOT/standalone"
assert_contains "$TEST_LOG" '<StartInterval> <-integer> <86400>'
assert_contains "$TEST_LOG" "launchctl <bootstrap> <system> <$TEST_ROOT/standalone/com.github.tart-runner-image-refresh.plist>"
python3 - "$TEST_ROOT/standalone/com.github.tart-runner-image-refresh.plist" <<'PLIST'
import plistlib
import sys
with open(sys.argv[1], "rb") as stream:
    assert plistlib.load(stream)["EnvironmentVariables"]["TART_UPDATE_MEMORY_MB"] == "4096"
PLIST
if grep -Eq '^(tart|ssh|curl) |com.github.tart-runner-[0-9]' "$TEST_LOG"; then
    echo 'FAIL: standalone installer touched an image or runner service'
    exit 1
fi
echo 'PASS: standalone checker installation needs no runner credentials or restart'

: >"$TEST_LOG"
bash "$SCRIPT_DIR/tart-install-image-updater.sh" --launchd-user test-user \
    --launchd-dir "$TEST_ROOT/calendar" --daily-at 03:00
python3 - "$TEST_ROOT/calendar/com.github.tart-runner-image-refresh.plist" <<'CALENDAR'
import plistlib
import sys
with open(sys.argv[1], "rb") as stream:
    value = plistlib.load(stream)
assert value["RunAtLoad"] is False
assert value["StartCalendarInterval"] == {"Hour": 3, "Minute": 0}
assert "StartInterval" not in value
CALENDAR
: >"$TEST_LOG"
if bash "$SCRIPT_DIR/tart-install-image-updater.sh" --daily-at 24:00; then
    echo 'FAIL: invalid calendar time accepted'
    exit 1
fi
[ ! -s "$TEST_LOG" ]
echo 'PASS: explicit 03:00 local scheduling has no run-at-load or interval and rejects invalid times'

: >"$TEST_LOG"
bash "$SCRIPT_DIR/bootstrap-tart-runners.sh" --count 1 --org example \
    --app-id 123 --private-key "$TEST_ROOT/app.pem" --install-launchd
if grep -Fq 'defaults ' "$TEST_LOG"; then exit 1; fi
assert_contains "$TEST_LOG" '<StartInterval> <-integer> <86400>'
assert_contains "$TEST_LOG" '<RunAtLoad> <-bool> <YES>'
assert_contains "$TEST_LOG" 'tart-update-image.sh'
assert_contains "$TEST_LOG" "launchctl <load> <$HOME/Library/LaunchAgents/com.github.tart-runner-image-refresh.plist>"
assert_contains "$HOME/Library/LaunchAgents/com.github.tart-runner-1.plist" "$TART_RUNNER_CONFIG_DIR"
echo 'PASS: bootstrap installs scheduled agent and shared image state'

: >"$TEST_LOG"
bash "$SCRIPT_DIR/bootstrap-tart-runners.sh" --count 1 --org example \
    --app-id 123 --private-key "$TEST_ROOT/app.pem" --install-launchd \
    --launchd-scope daemon --launchd-user test-user --launchd-dir "$TEST_ROOT/daemons" \
    --memory-mb 6144
assert_contains "$TEST_LOG" 'defaults <write> </Library/Preferences/com.apple.osanalytics> <309_CountLimit> <-int> <1000>'
assert_contains "$TEST_LOG" '<UserName> <-string> <test-user>'
assert_contains "$TEST_LOG" "launchctl <bootstrap> <system> <$TEST_ROOT/daemons/com.github.tart-runner-image-refresh.plist>"
python3 - "$TEST_ROOT/daemons/com.github.tart-runner-1.plist" <<'PLIST'
import plistlib
import sys
with open(sys.argv[1], "rb") as stream:
    assert plistlib.load(stream)["EnvironmentVariables"]["TART_GUEST_MEMORY_MB"] == "6144"
PLIST
echo 'PASS: daemon scheduler runs under the runner account'

: >"$TEST_LOG"
bash "$SCRIPT_DIR/bootstrap-tart-runners.sh" --count 1 --org example \
    --app-id 123 --private-key "$TEST_ROOT/app.pem" \
    --launchd-scope daemon --launchd-user test-user
if grep -Fq 'defaults ' "$TEST_LOG"; then exit 1; fi
echo 'PASS: image-only daemon bootstrap leaves host crash-report settings unchanged'

: >"$TEST_LOG"
bash "$SCRIPT_DIR/bootstrap-tart-runners.sh" --count 1 --org example \
    --app-id 123 --private-key "$TEST_ROOT/app.pem" --install-launchd --no-image-refresh
if grep -Fq 'plutil' "$TEST_LOG"; then exit 1; fi
echo 'PASS: explicit opt-out skips scheduler installation'

mkdir "$TEST_ROOT/bake-fixture"
cp "$SCRIPT_DIR/bootstrap-tart-runners.sh" "$SCRIPT_DIR/tart-common.sh" "$TEST_ROOT/bake-fixture/"
cat >"$TEST_ROOT/bake-fixture/tart-bake-ubuntu.sh" <<'BAKE'
#!/bin/bash
printf 'bake <%s>\n' "$*" >> "$TEST_LOG"
exit "${TEST_BAKE_EXIT:-0}"
BAKE
printf '%s\n' "$promoted" >"$pointer"
mkdir -p "$TART_RUNNER_CONFIG_DIR/images/gha-ubuntu-kvm.successful"
touch "$TART_RUNNER_CONFIG_DIR/images/gha-ubuntu-kvm.successful/gha-ubuntu-kvm"
bash "$TEST_ROOT/bake-fixture/bootstrap-tart-runners.sh" --count 1 --org example \
    --app-id 123 --private-key "$TEST_ROOT/app.pem" >"$TEST_ROOT/reuse-output"
assert_contains "$TEST_ROOT/reuse-output" "Runner image '$promoted' already exists"
if grep -Fq 'bake <' "$TEST_LOG"; then
    echo 'FAIL: selected versioned image was needlessly rebaked'
    exit 1
fi
bash "$TEST_ROOT/bake-fixture/bootstrap-tart-runners.sh" --count 1 --org example \
    --app-id 123 --private-key "$TEST_ROOT/app.pem" --rebuild-image
[ ! -f "$pointer" ]
[ ! -f "$TART_RUNNER_CONFIG_DIR/images/gha-ubuntu-kvm.successful/gha-ubuntu-kvm" ]
[ ! -d "$TART_RUNNER_CONFIG_DIR/images/gha-ubuntu-kvm.lock" ]
echo 'PASS: successful full rebake selects rebuilt base and releases lock'

printf '%s\n' "$promoted" >"$pointer"
export TEST_BAKE_EXIT=1
if bash "$TEST_ROOT/bake-fixture/bootstrap-tart-runners.sh" --count 1 --org example \
    --app-id 123 --private-key "$TEST_ROOT/app.pem" --rebuild-image; then
    echo 'FAIL: failed rebake accepted'
    exit 1
fi
[ "$(cat "$pointer")" = "$promoted" ]
[ ! -d "$TART_RUNNER_CONFIG_DIR/images/gha-ubuntu-kvm.lock" ]
echo 'PASS: failed full rebake preserves selected image and releases lock'
