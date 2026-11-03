#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_ROOT TEST_LOG="$TEST_ROOT/commands.log"
export TEST_DAEMONS="$TEST_ROOT/daemons"
export PATH="$TEST_ROOT/bin:$PATH"
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/source" "$TEST_DAEMONS"
cp "$SCRIPT_DIR/tart-common.sh" "$TEST_ROOT/source/"
sed "s|/Library/LaunchDaemons/|$TEST_DAEMONS/|g" \
    "$SCRIPT_DIR/tart-configure-runners.sh" >"$TEST_ROOT/source/tart-configure-runners.sh"
cat >"$TEST_ROOT/source/tart-install-image-updater.sh" <<'INSTALLER'
#!/bin/bash
set -euo pipefail
printf 'updater memory=%s config=%s key=%s args=%s\n' \
    "$TART_UPDATE_MEMORY_MB" "$TART_RUNNER_CONFIG_DIR" "$TART_SSH_KEY" "$*" >> "$TEST_LOG"
if [ "$TEST_UPDATER_FAIL" = 1 ]; then echo 'fixture updater installation failed' >&2; exit 1; fi
printf '%s\n' "$TART_UPDATE_MEMORY_MB" > "$TEST_ROOT/daily-installed"
INSTALLER

cat >"$TEST_ROOT/bin/mock" <<'MOCK'
#!/bin/bash
set -euo pipefail
command_name="${0##*/}"
printf '%s' "$command_name" >> "$TEST_LOG"
printf ' <%s>' "$@" >> "$TEST_LOG"
printf '\n' >> "$TEST_LOG"
case "$command_name" in
    id) echo "$TEST_UID" ;;
    uname) echo "$TEST_OS" ;;
    sysctl) echo "$TEST_RAM_BYTES" ;;
    launchctl)
        if [ "$1" = print ] && [ "$2" = "$TEST_UNLOADED" ]; then
            echo 'fixture service not loaded' >&2
            exit 1
        fi
        if [ "$1" = bootstrap ] && [ "$3" = "$TEST_BOOTSTRAP_FAIL" ]; then
            echo 'fixture bootstrap failed' >&2
            exit 1
        fi
        ;;
    plutil)
        python3 - "$@" <<'PLIST'
import json
import plistlib
import sys

args = sys.argv[1:]
path = args[-1]
with open(path, "rb") as stream:
    value = plistlib.load(stream)
if args[0] == "-convert":
    assert args[:4] == ["-convert", "json", "-o", "-"]
    print(json.dumps(value))
elif args[0] == "-replace":
    if args[1] == "ProgramArguments":
        assert args[2] == "-json"
        value["ProgramArguments"] = json.loads(args[3])
    else:
        assert args[1:3] == ["EnvironmentVariables.TART_GUEST_MEMORY_MB", "-string"]
        value.setdefault("EnvironmentVariables", {})["TART_GUEST_MEMORY_MB"] = args[3]
    with open(path, "wb") as stream:
        plistlib.dump(value, stream)
else:
    assert args[0] == "-lint"
PLIST
        ;;
    *) echo "Unexpected mock: $command_name" >&2; exit 1 ;;
esac
MOCK
chmod +x "$TEST_ROOT/bin/mock"
for command_name in id uname sysctl launchctl plutil; do
    ln -s mock "$TEST_ROOT/bin/$command_name"
done

reset_case() {
    export TEST_UID=0 TEST_OS=Darwin TEST_RAM_BYTES=34359738368
    export TEST_UNLOADED="" TEST_BOOTSTRAP_FAIL="" TEST_UPDATER_FAIL=0
    : >"$TEST_LOG"
    rm -f "$TEST_ROOT/daily-installed"
    python3 - <<'PLISTS'
import os
import plistlib

root = os.environ["TEST_ROOT"]
for index in (1, 2, 3):
    value = {
        "Label": f"com.github.tart-runner-{index}",
        "UserName": "fixture-user",
        "ProgramArguments": [
            "/bin/bash", f"{root}/source/tart-runner-loop.sh",
            "--index", str(index), "--golden-image", "custom-image",
            "--labels", "arm64,kvm,linux,ubuntu-24.04", "--name-prefix", "keep-prefix",
        ],
        "EnvironmentVariables": {
            "KEEP_ME": "unchanged",
            "TART_RUNNER_CONFIG_DIR": f"{root}/config",
            "TART_SSH_KEY": f"{root}/config/key",
        },
    }
    if index != 2:
        value["EnvironmentVariables"]["TART_GUEST_MEMORY_MB"] = "2048"
    with open(f"{root}/daemons/com.github.tart-runner-{index}.plist", "wb") as stream:
        plistlib.dump(value, stream)
PLISTS
}

configure() {
    bash "$TEST_ROOT/source/tart-configure-runners.sh" "$@" >"$TEST_ROOT/output" 2>&1
}
assert_contains() { grep -Fq -- "$2" "$1" || {
    cat "$1"
    echo "FAIL: missing '$2'" >&2
    exit 1
}; }
assert_no_mutations() {
    if grep -Eq '^plutil <-replace>|^launchctl <(bootout|bootstrap)>|^updater ' "$TEST_LOG"; then
        echo 'FAIL: preflight failure changed services' >&2
        exit 1
    fi
}
expect_failure() {
    local message="$1"
    shift
    if configure "$@"; then
        echo "FAIL: accepted $message" >&2
        exit 1
    fi
    assert_contains "$TEST_ROOT/output" "$message"
}

reset_case
configure 2 8 || {
    cat "$TEST_ROOT/output"
    exit 1
}
python3 - <<'VERIFY'
import os
import plistlib
for index in (1, 2, 3):
    with open(f'{os.environ["TEST_DAEMONS"]}/com.github.tart-runner-{index}.plist', "rb") as stream:
        value = plistlib.load(stream)
    assert value["EnvironmentVariables"]["TART_GUEST_MEMORY_MB"] == ("2048" if index == 3 else "8192")
    assert value["EnvironmentVariables"]["KEEP_ME"] == "unchanged"
VERIFY
[ "$(grep -c '^launchctl <bootout>' "$TEST_LOG")" -eq 2 ]
[ "$(grep -c '^launchctl <bootstrap>' "$TEST_LOG")" -eq 2 ]
[ "$(grep -c '^updater ' "$TEST_LOG")" -eq 1 ]
[ "$(cat "$TEST_ROOT/daily-installed")" = 4096 ]
assert_contains "$TEST_LOG" '--launchd-user fixture-user --golden-image custom-image'
assert_contains "$TEST_LOG" "config=$TEST_ROOT/config key=$TEST_ROOT/config/key"
echo 'PASS: updates runners 1..N, preserves unrelated settings/services, and installs the matching 4 GiB updater'

reset_case
export TEST_RAM_BYTES=17179869184
configure 2 6 --force --labels arm64,kvm,linux --daily-at 03:00
assert_contains "$TEST_ROOT/output" 'WARNING: --force host memory overcommit'
assert_contains "$TEST_ROOT/output" 'jobs=12288 MiB'
assert_contains "$TEST_ROOT/output" 'updater=4096 MiB, host=16384 MiB, macOS headroom=0 MiB'
assert_contains "$TEST_ROOT/output" 'Guest swap is not host RAM'
assert_contains "$TEST_LOG" '--daily-at 03:00'
python3 - <<'LABELS'
import os
import plistlib
for index in (1, 2, 3):
    with open(f'{os.environ["TEST_DAEMONS"]}/com.github.tart-runner-{index}.plist', "rb") as stream:
        value = plistlib.load(stream)
    args = value["ProgramArguments"]
    assert args.count("--labels") == 1
    assert args[args.index("--labels") + 1] == ("arm64,kvm,linux,ubuntu-24.04" if index == 3 else "arm64,kvm,linux")
    assert args[args.index("--name-prefix") + 1] == "keep-prefix"
    assert value["EnvironmentVariables"]["TART_GUEST_MEMORY_MB"] == ("2048" if index == 3 else "6144")
LABELS
echo 'PASS: force warns with exact physical budget; labels persist in arguments and calendar mode is forwarded'

reset_case
configure --help
assert_no_mutations
for arguments in '0 8' '2 -1' 'two 8' '2 1.5' '9999999 8' '1 9999999'; do
    read -r count memory <<<"$arguments"
    expect_failure 'positive integer' "$count" "$memory"
    assert_no_mutations
done
expect_failure 'Provide a runner count' 1
assert_no_mutations
export TEST_RAM_BYTES=17179869184
expect_failure 'leave no RAM for macOS' 2 6
assert_no_mutations
expect_failure 'leave no RAM for macOS' 2 8
assert_no_mutations
expect_failure 'leave no RAM for macOS' 1 12
assert_no_mutations
export TEST_UID=501
expect_failure 'with sudo' 1 8
assert_no_mutations
export TEST_UID=0 TEST_OS=Linux
expect_failure 'macOS only' 1 8
assert_no_mutations
echo 'PASS: rejects invalid input, insufficient host RAM, non-root and non-macOS before mutations'

reset_case
expect_failure 'positive integer' 2 invalid --force
assert_no_mutations
expect_failure 'Unknown argument' 2 6 --force --typo
assert_no_mutations
expect_failure '--labels requires' 2 6 --force --labels ""
assert_no_mutations
expect_failure '--daily-at requires' 2 6 --force --daily-at 24:00
assert_no_mutations
export TEST_UID=501
expect_failure 'with sudo' 2 6 --force
assert_no_mutations
export TEST_UID=0 TEST_OS=Linux
expect_failure 'macOS only' 2 6 --force
assert_no_mutations
reset_case
rm "$TEST_DAEMONS/com.github.tart-runner-2.plist"
expect_failure 'Missing or unsafe service file' 2 6 --force
assert_no_mutations
reset_case
export TEST_UNLOADED=system/com.github.tart-runner-2
expect_failure 'Service is not loaded' 2 6 --force
assert_no_mutations
echo 'PASS: force does not bypass argument, platform, privilege or service validation'

reset_case
rm "$TEST_DAEMONS/com.github.tart-runner-2.plist"
expect_failure 'Missing or unsafe service file' 2 8
assert_no_mutations
reset_case
export TEST_UNLOADED=system/com.github.tart-runner-2
expect_failure 'Service is not loaded' 2 8
assert_no_mutations
reset_case
python3 - <<'OWNER'
import os
import plistlib
path = f'{os.environ["TEST_DAEMONS"]}/com.github.tart-runner-2.plist'
with open(path, "rb") as stream:
    value = plistlib.load(stream)
value["UserName"] = "other-user"
with open(path, "wb") as stream:
    plistlib.dump(value, stream)
OWNER
expect_failure 'must share the same Tart owner' 2 8
assert_no_mutations
echo 'PASS: checks all target files, loaded services and shared updater settings before changing runner 1'

reset_case
export TEST_BOOTSTRAP_FAIL="$TEST_DAEMONS/com.github.tart-runner-2.plist"
expect_failure 'fixture bootstrap failed' 2 8
[ ! -f "$TEST_ROOT/daily-installed" ]
reset_case
export TEST_UPDATER_FAIL=1
expect_failure 'fixture updater installation failed' 1 8
[ ! -f "$TEST_ROOT/daily-installed" ]
echo 'PASS: restart and daily-updater installation failures return non-zero instead of claiming success'
