#!/bin/bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="$TEST_ROOT/home" TEST_LOG="$TEST_ROOT/commands.log" TEST_FAIL_LOG=0
export TART_DEBUG_LOG_DIR="$TEST_ROOT/logs"
export PATH="$TEST_ROOT/bin:$PATH"
mkdir -p "$TEST_ROOT/bin" "$HOME" "$TART_DEBUG_LOG_DIR"

cat >"$TEST_ROOT/bin/log" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_LOG"
echo 'Log limit exceeded'
for ((i = 0; i < 350; i++)); do
    echo "system log line $i"
done
[ "$TEST_FAIL_LOG" = 0 ]
MOCK
cat >"$TEST_ROOT/bin/tart" <<'MOCK'
#!/bin/bash
echo 'fixture VM list'
MOCK
chmod +x "$TEST_ROOT/bin/"*

# Redirect the system report path to the fixture.
sed "s|\"/Library/Logs/DiagnosticReports\"|\"$TEST_ROOT/system-reports\"|" \
    "$SCRIPT_DIR/tart-common.sh" >"$TEST_ROOT/tart-common.sh"
source "$TEST_ROOT/tart-common.sh"
install_err_diagnostics fixture

runtime_log="$TART_DEBUG_LOG_DIR/tart-runner-1-vm-fixture.log"
job_output="$TART_DEBUG_LOG_DIR/tart-runner-1-job-output.fixture"
printf 'VZErrorDomain Code=1\n' >"$runtime_log"
printf 'repo: owner/repo\nrun: fixture-run\n' >"$job_output"
printf '2026-11-03 12:00:00\n' >"${runtime_log}.started"
touch -t 202611031200 "${runtime_log}.started"
diag_log="$TART_DEBUG_LOG_DIR/tart-runner-1-vm-diagnostics.log"

assert_contains() {
    if ! grep -Fq -- "$2" "$1"; then
        echo "FAIL: missing '$2' in $1" >&2
        exit 1
    fi
}

latest_bundle() {
    sed -n 's/^bundle=//p' "$diag_log" | tail -n 1
}

capture_host_vm_diagnostics tart-runner-1 fixture-vm "$runtime_log" "$job_output"
bundle="$(latest_bundle)"
assert_contains "$diag_log" "Report directory missing: $TEST_ROOT/system-reports"
assert_contains "$diag_log" "Report directory missing: $HOME/Library/Logs/DiagnosticReports"
assert_contains "$TEST_LOG" '--start 2026-11-03 12:00:00'
assert_contains "$TEST_LOG" 'ReportCrash'
assert_contains "$bundle/system.log" 'Log limit exceeded'
assert_contains "$bundle/system.log" 'system log line 0'
assert_contains "$bundle/system.log" 'system log line 349'
cmp "$runtime_log" "$bundle/tart.log"
cmp "$job_output" "$bundle/runner.log"
echo 'PASS: missing report directories allow full system and runner log collection'

mkdir -p "$TEST_ROOT/system-reports" "$HOME/Library/Logs/DiagnosticReports"
report="$TEST_ROOT/system-reports/com.apple.Virtualization.VirtualMachine-current.ips"
other="$TEST_ROOT/system-reports/com.apple.Virtualization.VirtualMachine-other.ips"
old="$TEST_ROOT/system-reports/com.apple.Virtualization.VirtualMachine-old.ips"
unknown="$TEST_ROOT/system-reports/com.apple.Virtualization.VirtualMachine-unknown.ips"
user_report="$HOME/Library/Logs/DiagnosticReports/tart report.crash"
printf '{"bug_type":"309"}\n{"coalitionName":"com.github.tart-runner-1","threads":[{"triggered":true}]}\n' >"$report"
printf '{"coalitionName":"com.github.tart-runner-2"}\n' >"$other"
cp "$report" "$old"
printf '{"bug_type":"309"}\n{"threads":[]}\n' >"$unknown"
printf 'full user crash report\n' >"$user_report"
touch -t 202611031201 "$report" "$other" "$unknown" "$user_report"
touch -t 202611031159 "$old"
capture_host_vm_diagnostics tart-runner-1 fixture-vm "$runtime_log" "$job_output"
next_bundle="$(latest_bundle)"
[ "$next_bundle" != "$bundle" ]
cmp "$report" "$next_bundle/system/${report##*/}"
cmp "$unknown" "$next_bundle/system/${unknown##*/}"
cmp "$user_report" "$next_bundle/user/${user_report##*/}"
[ ! -f "$next_bundle/system/${other##*/}" ]
[ ! -f "$next_bundle/system/${old##*/}" ]
echo 'PASS: each bundle saves complete reports from the iteration and excludes other runner coalitions'

export TEST_FAIL_LOG=1
capture_host_vm_diagnostics tart-runner-1 fixture-vm "$runtime_log" "$job_output"
bundle="$(latest_bundle)"
assert_contains "$diag_log" 'Could not read the system log.'
cmp "$report" "$bundle/system/${report##*/}"
echo 'PASS: system log failure does not prevent crash report collection'
