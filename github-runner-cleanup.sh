#!/bin/bash
#
# GitHub Actions Runner — Post-Job Cleanup Hook (single source of truth)
#
# This is the canonical post-job cleanup hook. The bootstrap script copies it
# into each runner directory as job-completed-hook.sh and wires it up via the
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED environment variable in the runner .env, so
# the runner invokes it automatically after every job.
#
# GitHub Actions hooks receive NO arguments, so the runner directory is derived
# from this script's own location ($0) rather than a positional parameter.
#
# Purpose: wipe the _work directory so build artifacts never leak between jobs.
# NOTE: this clears _work only — it does NOT isolate jobs from the rest of the
# host (Homebrew, /tmp, caches, keychains, etc. persist). See the README
# trade-off note for the macOS / AVF runners.
#
# Exit code is always 0: the job has already finished, so a cleanup failure is
# logged for diagnostics but never fails the run.

set -u

# The runner copies this script into its own directory, so $0 lives alongside
# the _work directory we need to clean.
RUNNER_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_FILE="${RUNNER_DIR}/.cleanup.log"

{
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Post-job cleanup started"

    if [ ! -d "$RUNNER_DIR/_work" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] _work directory not found; nothing to do"
        exit 0
    fi

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleaning _work/*..."
    rm -rf "$RUNNER_DIR/_work"/* 2>&1 || {
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARNING: cleanup failed (non-fatal)"
        exit 0
    }

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Cleanup complete"
} >> "$LOG_FILE" 2>&1

exit 0
