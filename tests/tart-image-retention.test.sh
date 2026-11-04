#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export TEST_ROOT TEST_DB="$TEST_ROOT/vms.json" TEST_LOG="$TEST_ROOT/commands.log"
export TART_RUNNER_CONFIG_DIR="$TEST_ROOT/config"
export TART_DEBUG_LOG_DIR="$TEST_ROOT/logs" TART_CACHE_DIR="$TEST_ROOT/cache"
export TEST_JOB_RESULT=Succeeded TEST_SSH_EXIT=0 TEST_DELETE_FAIL="" TEST_CLONE_FAIL=0
export TEST_RUNNER_HOST=fixture-mac
export TART_GUEST_MEMORY_MB=8192 TEST_MEMORY_FAIL=0
export TEST_BAD_RESOURCES=""
export TEST_POLICY_FAIL=0
export PATH="$TEST_ROOT/bin:$PATH"
mkdir -p "$TEST_ROOT/bin" "$TART_DEBUG_LOG_DIR"

cat > "$TEST_ROOT/bin/tart" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$TEST_LOG"
case "$1" in
    list) cat "$TEST_DB" ;;
    get)
        if [[ "$*" == *'--format json'* ]]; then
            case "$TEST_BAD_RESOURCES" in
                cpu) echo '{"CPU":0,"Memory":8192}' ;;
                memory) echo '{"CPU":2,"Memory":"invalid"}' ;;
                *) jq -e --arg image "$2" '.[] | select(.Name == $image)' "$TEST_DB" ;;
            esac
        else
            jq -e --arg image "$2" 'any(.[]; .Name == $image)' "$TEST_DB" >/dev/null
        fi
        ;;
    clone)
        [ "$TEST_CLONE_FAIL" = 0 ] || exit 1
        jq -e --arg image "$2" 'any(.[]; .Name == $image)' "$TEST_DB" >/dev/null
        jq --arg source "$2" --arg image "$3" \
            '. + [(.[] | select(.Name == $source) | .Name = $image | .State = "stopped" | .Running = false)]' \
            "$TEST_DB" > "$TEST_DB.tmp"
        mv "$TEST_DB.tmp" "$TEST_DB"
        ;;
    delete)
        [ "$2" != "$TEST_DELETE_FAIL" ] || exit 1
        jq --arg image "$2" 'map(select(.Name != $image))' "$TEST_DB" > "$TEST_DB.tmp"
        mv "$TEST_DB.tmp" "$TEST_DB"
        ;;
    ip) echo 192.0.2.1 ;;
    set)
        [ "$TEST_MEMORY_FAIL" = 0 ] || exit 1
        [ "$3" = --memory ]
        jq --arg image "$2" --argjson memory "$4" \
            'map(if .Name == $image then .Memory = $memory else . end)' "$TEST_DB" > "$TEST_DB.tmp"
        mv "$TEST_DB.tmp" "$TEST_DB"
        ;;
    run)
        memory="$(jq -r --arg image "${*: -1}" '.[] | select(.Name == $image) | .Memory' "$TEST_DB")"
        [ "$memory" = "$TART_GUEST_MEMORY_MB" ]
        printf 'job-boot-memory %s\n' "$memory" >> "$TEST_LOG"
        ;;
    stop) ;;
    *) echo "Unexpected Tart operation: $*" >&2; exit 1 ;;
esac
MOCK
cat > "$TEST_ROOT/bin/ssh" <<'MOCK'
#!/bin/bash
set -euo pipefail
if [[ "${*: -1}" == *'sudo bash -s -- install '* ]]; then
    cat > "$TEST_ROOT/guest-policy"
    [ "$TEST_POLICY_FAIL" = 0 ] || exit 1
    echo false
    exit 0
fi
if [[ "${*: -1}" == *'./run.sh'* ]]; then
    printf '%s\n' "${*: -1}" > "$TEST_ROOT/runner-command"
    printf "Current runner version: '2.338.2'\n"
    if [ "$TEST_JOB_RESULT" != none ]; then
        printf '2026-11-03 15:09:45Z: Job build / test completed with result: %s\r\n' "$TEST_JOB_RESULT"
    fi
    exit "$TEST_SSH_EXIT"
fi
MOCK
cat > "$TEST_ROOT/bin/pkill" <<'MOCK'
#!/bin/bash
exit 0
MOCK
cat > "$TEST_ROOT/bin/hostname" <<'MOCK'
#!/bin/bash
[ "$1" = -s ] || exit 1
printf '%s\n' "$TEST_RUNNER_HOST"
MOCK
chmod +x "$TEST_ROOT/bin/"*
source "$SCRIPT_DIR/tart-common.sh"
base=gha-ubuntu-kvm
old="$base-runner-v2.337.0-100-1"
good="$base-runner-v2.338.0-200-1"
current="$base-runner-v2.338.2-300-1"
newer="$base-runner-v2.338.2-400-1"
state="$TART_RUNNER_CONFIG_DIR/images"

reset_case() {
    rm -rf "$TART_RUNNER_CONFIG_DIR"
    mkdir -p "$state"
    : > "$TEST_LOG"
    export TEST_DELETE_FAIL="" TEST_CLONE_FAIL=0 TEST_MEMORY_FAIL=0 TEST_BAD_RESOURCES=""
    jq -n --arg base "$base" --arg old "$old" --arg good "$good" --arg current "$current" \
        '[$base, $old, $good, $current, "unrelated-vm", "other-runner-v2.0.0-1-1"] |
         map({Name: ., State: "stopped", Running: false, Memory: 4096, CPU: 2})' > "$TEST_DB"
    printf '%s\n' "$current" > "$state/$base.current"
    with_image_state_lock register_runner_images_locked
}

exists() { jq -e --arg image "$1" 'any(.[]; .Name == $image)' "$TEST_DB" >/dev/null; }
passed() {
    mkdir -p "$state/$base.successful"
    touch "$state/$base.successful/$1"
}
assert_contains() { grep -Fq -- "$2" "$1" || { echo "FAIL: missing '$2' in $1" >&2; exit 1; }; }

reset_case
with_image_state_lock prune_runner_images_locked
exists "$base" && exists "$current"
! exists "$old"
! exists "$good"
[ ! -f "$state/$base.lkg" ]
echo 'PASS: no boot-only image counts as LKG; initial retention is bounded to selected plus original'

reset_case
passed "$old"
passed "$good"
with_image_state_lock prune_runner_images_locked
exists "$current" && exists "$good" && exists unrelated-vm && exists other-runner-v2.0.0-1-1
! exists "$old"
! exists "$base"
[ "$(cat "$state/$base.lkg")" = "$good" ]
with_image_state_lock record_runner_image_success_locked "$current"
[ "$(cat "$state/$base.lkg")" = "$good" ]
echo 'PASS: keeps selected plus newest previous job-proven image, not all previous successes'

reset_case
passed "$old"
passed "$good"
with_image_state_lock record_runner_image_success_locked "$current"
tart clone "$current" "$newer"
with_image_state_lock select_runner_image_locked "$newer"
with_image_state_lock prune_runner_images_locked
exists "$newer" && exists "$current"
! exists "$good"
[ "$(cat "$state/$base.lkg")" = "$current" ]
with_image_state_lock record_runner_image_success_locked "$newer"
[ "$(cat "$state/$base.lkg")" = "$current" ]
echo 'PASS: next promotion moves the previously successful selected image into the rollback slot'

reset_case
passed "$good"
same_second="$base-runner-v2.338.0-200-2"
tart clone "$good" "$same_second"
with_image_state_lock register_runner_images_locked
passed "$same_second"
with_image_state_lock record_runner_image_success_locked "$old"
exists "$same_second"
! exists "$good"
[ "$(cat "$state/$base.lkg")" = "$same_second" ]
echo 'PASS: late success from an older image cannot displace the newer proven rollback image'

reset_case
passed "$good"
source_image="$(with_image_state_lock clone_runner_image_locked "$base-runner-1")"
[ "$source_image" = "$current" ]
[ "$(cat "$state/$base.in-use/$base-runner-1")" = "$current" ]
[ "$(jq -r --arg image "$base-runner-1" '.[] | select(.Name == $image) | .Memory' "$TEST_DB")" = 8192 ]
[ "$(jq -r --arg image "$current" '.[] | select(.Name == $image) | .Memory' "$TEST_DB")" = 4096 ]
with_image_state_lock select_runner_image_locked "$good"
with_image_state_lock prune_runner_images_locked
exists "$current"
tart delete "$base-runner-1"
with_image_state_lock release_runner_image_locked "$base-runner-1"
with_image_state_lock prune_runner_images_locked
! exists "$current"
echo 'PASS: cloning records the exact source under lock; leased images survive until clone cleanup'

reset_case
passed "$good"
jq --arg image "$old" 'map(if .Name == $image then .State = "running" | .Running = true else . end)' \
    "$TEST_DB" > "$TEST_DB.tmp"
mv "$TEST_DB.tmp" "$TEST_DB"
with_image_state_lock prune_runner_images_locked
exists "$old"
reset_case
passed "$good"
tart clone "$base" "$base-runner-2"
with_image_state_lock prune_runner_images_locked
exists "$old" && exists "$base"
echo 'PASS: directly running images and untracked legacy clones prevent unsafe deletion'

reset_case
passed "$good"
export TEST_DELETE_FAIL="$base"
if with_image_state_lock prune_runner_images_locked; then
    echo 'FAIL: deletion error was hidden' >&2
    exit 1
fi
exists "$base"
[ -f "$state/$base.managed/$base" ]
[ ! -d "$state/$base.selection-lock" ]
export TEST_DELETE_FAIL=""
echo 'PASS: deletion errors preserve tracking and release the lock'

reset_case
export TEST_CLONE_FAIL=1
if with_image_state_lock clone_runner_image_locked "$base-runner-1"; then exit 1; fi
[ ! -f "$state/$base.in-use/$base-runner-1" ]
export TEST_CLONE_FAIL=0
printf 'bad/image\n' > "$state/$base.current"
if with_image_state_lock prune_runner_images_locked; then exit 1; fi
! grep -q '^delete ' "$TEST_LOG"
printf '{}\n' > "$TEST_DB"
if with_image_state_lock register_runner_images_locked; then exit 1; fi
echo 'PASS: invalid selection, invalid inventory and failed clones fail closed'

reset_case
export TEST_MEMORY_FAIL=1
if with_image_state_lock clone_runner_image_locked "$base-runner-1"; then exit 1; fi
! exists "$base-runner-1"
[ ! -f "$state/$base.in-use/$base-runner-1" ]
export TEST_DELETE_FAIL="$base-runner-1"
if with_image_state_lock clone_runner_image_locked "$base-runner-1"; then exit 1; fi
exists "$base-runner-1"
[ -f "$state/$base.in-use/$base-runner-1" ]
echo 'PASS: failed job memory configuration prevents boot and cleans or protects the failed clone'

reset_case
passed "$base"
passed "$good"
with_image_state_lock reset_baked_image_state_locked
[ ! -f "$state/$base.current" ]
[ ! -f "$state/$base.successful/$base" ]
[ -f "$state/$base.successful/$good" ]
echo 'PASS: rebaking the original image invalidates its old successful-job proof only'

reset_case
passed "$good"
with_image_state_lock record_runner_image_success_locked "$current" > "$TEST_ROOT/success-one.log" &
first_pid=$!
with_image_state_lock record_runner_image_success_locked "$good" > "$TEST_ROOT/success-two.log" &
second_pid=$!
wait "$first_pid"
wait "$second_pid"
exists "$current" && exists "$good"
[ "$(cat "$state/$base.lkg")" = "$good" ]
[ "$(grep -c "^delete $base$" "$TEST_LOG")" -eq 1 ]
echo 'PASS: concurrent success reports serialize retention and never double-delete'

for result in Succeeded Failed Canceled Skipped none; do
    : > "$TEST_ROOT/job-output"
    if [ "$result" != none ]; then
        printf '2026-11-03 15:09:45Z: Job build / test completed with result: %s\r\n' "$result" > "$TEST_ROOT/job-output"
    fi
    if [ "$result" = Succeeded ]; then
        runner_job_succeeded "$TEST_ROOT/job-output"
    else
        ! runner_job_succeeded "$TEST_ROOT/job-output"
    fi
done
printf 'Job finished; tearing down clone\nUpdate finished successfully.\n' > "$TEST_ROOT/job-output"
! runner_job_succeeded "$TEST_ROOT/job-output"
echo 'PASS: only a real Succeeded job result counts, including CRLF runner output'

(
    set -E
    export HOME="$TEST_ROOT/missing-home"
    cat > "$TEST_ROOT/bin/log" <<'LOG'
#!/bin/bash
echo "system log fixture: $*"
LOG
    chmod +x "$TEST_ROOT/bin/log"
    sed "s|\"/Library/Logs/DiagnosticReports\"|\"$TEST_ROOT/system-reports\"|" \
        "$SCRIPT_DIR/tart-common.sh" > "$TEST_ROOT/diagnostics-common.sh"
    source "$TEST_ROOT/diagnostics-common.sh"
    install_err_diagnostics fixture
    capture_host_vm_diagnostics tart-runner-1 fixture-vm
    diag_log="$TART_DEBUG_LOG_DIR/tart-runner-1-vm-diagnostics.log"
    assert_contains "$diag_log" 'system log fixture: show'
    assert_contains "$diag_log" 'ReportCrash'
    echo 'PASS: missing report directories allow system log collection'

    mkdir "$TEST_ROOT/system-reports"
    report="$TEST_ROOT/system-reports/com.apple.Virtualization.VirtualMachine-fixture.ips"
    printf '%s\n' report-start {1..130} report-end > "$report"
    capture_host_vm_diagnostics tart-runner-1 fixture-vm
    assert_contains "$diag_log" "$report"
    assert_contains "$diag_log" report-start
    assert_contains "$diag_log" report-end
    echo 'PASS: system crash reports are collected in full with a missing user directory'
)

mkdir "$TEST_ROOT/source"
cp "$SCRIPT_DIR/tart-common.sh" "$SCRIPT_DIR/tart-guest-memory.sh" "$TEST_ROOT/source/"
cat >> "$TEST_ROOT/source/tart-common.sh" <<'DIAGNOSTICS'
capture_host_vm_diagnostics() {
    echo 'fixture VM diagnostics' >&2
    [ "${TEST_DIAGNOSTICS_FAIL:-0}" = 0 ]
}
DIAGNOSTICS
sed -e 's/^while true; do$/for _test_iteration in 1; do/' \
    -e 's/^        sleep 10$/        :/' "$SCRIPT_DIR/tart-runner-loop.sh" \
    > "$TEST_ROOT/source/tart-runner-loop.sh"
cat > "$TEST_ROOT/source/tart-github-app-token.sh" <<'TOKEN'
mint_registration_token() { printf '%s\n' fixture-token; }
TOKEN
touch "$TEST_ROOT/app.pem"
for result in Succeeded Failed none; do
    reset_case
    passed "$good"
    export TEST_JOB_RESULT="$result" TEST_SSH_EXIT=0
    bash "$TEST_ROOT/source/tart-runner-loop.sh" --app-id 123 --private-key "$TEST_ROOT/app.pem" \
        --repo owner/repo > "$TEST_ROOT/loop-output" 2>&1 || { cat "$TEST_ROOT/loop-output"; exit 1; }
    grep -Eq 'Configuring \+ running ephemeral runner: tart-ubuntu-fixture-mac-1-2cpu-8GiB-[0-9]+$' "$TEST_ROOT/loop-output"
    assert_contains "$TEST_ROOT/runner-command" "--name 'tart-ubuntu-fixture-mac-1-2cpu-8GiB-"
    assert_contains "$TEST_LOG" 'job-boot-memory 8192'
    if [ "$result" = Succeeded ]; then
        [ -f "$state/$base.successful/$current" ]
        assert_contains "$TEST_ROOT/loop-output" "Runner image completed a successful job: $current"
    else
        [ ! -f "$state/$base.successful/$current" ]
    fi
    [ ! -f "$state/$base.in-use/$base-runner-1" ]
    ! exists "$base-runner-1"
    [ -z "$(find "$TART_DEBUG_LOG_DIR" -name '*-job-output.*' -print)" ]
done
echo 'PASS: real loop pipeline records successful jobs only and cleans transcript, clone and lease'

reset_case
rm -f "$TEST_ROOT/runner-command"
export TEST_POLICY_FAIL=1
bash "$TEST_ROOT/source/tart-runner-loop.sh" --app-id 123 --private-key "$TEST_ROOT/app.pem" \
    --repo owner/repo > "$TEST_ROOT/loop-output" 2>&1 || { cat "$TEST_ROOT/loop-output"; exit 1; }
assert_contains "$TEST_ROOT/loop-output" 'Guest swap validation failed; runner will not register'
[ ! -f "$TEST_ROOT/runner-command" ]
[ ! -f "$state/$base.in-use/$base-runner-1" ]
! exists "$base-runner-1"
export TEST_POLICY_FAIL=0
echo 'PASS: required swap failure prevents runner registration and releases the clone and source lease'

reset_case
export TEST_RUNNER_HOST=second-mac TEST_JOB_RESULT=Succeeded
export TART_GUEST_MEMORY_MB=6144
jq --arg image "$current" 'map(if .Name == $image then .CPU = 6 else . end)' \
    "$TEST_DB" > "$TEST_DB.tmp"
mv "$TEST_DB.tmp" "$TEST_DB"
bash "$TEST_ROOT/source/tart-runner-loop.sh" --app-id 123 --private-key "$TEST_ROOT/app.pem" \
    --repo owner/repo --name-prefix custom --index 2 > "$TEST_ROOT/loop-output" 2>&1 \
    || { cat "$TEST_ROOT/loop-output"; exit 1; }
grep -Eq 'Configuring \+ running ephemeral runner: custom-second-mac-2-6cpu-6GiB-[0-9]+$' "$TEST_ROOT/loop-output"
assert_contains "$TEST_ROOT/runner-command" "--name 'custom-second-mac-2-6cpu-6GiB-"
assert_contains "$TEST_LOG" 'job-boot-memory 6144'
export TART_GUEST_MEMORY_MB=8192
echo 'PASS: default and custom prefixes include the host, runner index and ephemeral suffix'

reset_case
export TART_GUEST_MEMORY_MB=1536
bash "$TEST_ROOT/source/tart-runner-loop.sh" --app-id 123 --private-key "$TEST_ROOT/app.pem" \
    --repo owner/repo > "$TEST_ROOT/loop-output" 2>&1 || { cat "$TEST_ROOT/loop-output"; exit 1; }
assert_contains "$TEST_ROOT/runner-command" "--name 'tart-ubuntu-second-mac-1-2cpu-1536MiB-"
export TART_GUEST_MEMORY_MB=8192
echo 'PASS: names reflect actual CPU and RAM allocations, with exact MiB for non-whole GiB sizes'

for bad_resource in cpu memory; do
    reset_case
    rm -f "$TEST_ROOT/runner-command"
    export TEST_BAD_RESOURCES="$bad_resource"
    bash "$TEST_ROOT/source/tart-runner-loop.sh" --app-id 123 --private-key "$TEST_ROOT/app.pem" \
        --repo owner/repo > "$TEST_ROOT/loop-output" 2>&1 || { cat "$TEST_ROOT/loop-output"; exit 1; }
    assert_contains "$TEST_ROOT/loop-output" 'Could not read VM CPU and memory allocation for runner name'
    [ ! -f "$TEST_ROOT/runner-command" ]
    [ ! -f "$state/$base.in-use/$base-runner-1" ]
    ! exists "$base-runner-1"
done
echo 'PASS: invalid CPU or RAM metadata prevents registration and cleans the clone'

for invalid_host in "" "invalid host"; do
    reset_case
    export TEST_RUNNER_HOST="$invalid_host"
    if bash "$TEST_ROOT/source/tart-runner-loop.sh" --app-id 123 --private-key "$TEST_ROOT/app.pem" \
        --repo owner/repo > "$TEST_ROOT/loop-output" 2>&1; then
        echo 'FAIL: invalid hostname accepted' >&2
        exit 1
    fi
    assert_contains "$TEST_ROOT/loop-output" 'Invalid runner host name:'
    ! grep -q '^clone ' "$TEST_LOG"
done
export TEST_RUNNER_HOST=fixture-mac
echo 'PASS: empty or invalid hostnames fail explicitly before cloning or registration'

reset_case
passed "$good"
export TEST_JOB_RESULT=Succeeded TEST_SSH_EXIT=1 TART_KEEP_FAILED_VM=1
bash "$TEST_ROOT/source/tart-runner-loop.sh" --app-id 123 --private-key "$TEST_ROOT/app.pem" \
    --repo owner/repo > "$TEST_ROOT/loop-output" 2>&1 || { cat "$TEST_ROOT/loop-output"; exit 1; }
[ ! -f "$state/$base.successful/$current" ]
[ -f "$state/$base.in-use/$base-runner-1" ]
exists "$base-runner-1"
assert_contains "$TEST_ROOT/loop-output" 'Keeping failed VM clone for inspection'
[ -z "$(find "$TART_DEBUG_LOG_DIR" -name '*-job-output.*' -print)" ]
echo 'PASS: failed SSH never certifies a job and retained diagnostic clones keep their source leases'

reset_case
export TEST_DIAGNOSTICS_FAIL=1 TEST_SSH_EXIT=1 TART_KEEP_FAILED_VM=0
bash "$TEST_ROOT/source/tart-runner-loop.sh" --app-id 123 --private-key "$TEST_ROOT/app.pem" \
    --repo owner/repo > "$TEST_ROOT/loop-output" 2>&1 || { cat "$TEST_ROOT/loop-output"; exit 1; }
assert_contains "$TEST_ROOT/loop-output" 'Host VM diagnostic collection failed'
assert_contains "$TEST_ROOT/loop-output" 'Failure reason: remote runner command exited non-zero'
[ ! -f "$state/$base.in-use/$base-runner-1" ]
! exists "$base-runner-1"
[ -s "$TART_CONFIG_DIR/runner-1.failure-epochs" ]
echo 'PASS: diagnostic failure does not interrupt clone cleanup or failure tracking'
