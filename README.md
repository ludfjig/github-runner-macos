# macOS GitHub Actions Runner Setup

These scripts install GitHub Actions runners on Apple Silicon Macs. You can run
both types on the same Mac:

1. **macOS / AVF runners:** jobs run directly on the Mac and can use Apple's
  Virtualization.framework (AVF). Only the runner's `_work` directory is cleared
  after each job. Changes elsewhere on the Mac remain and can affect later jobs.
2. **Ubuntu / KVM runners:** each job runs in a fresh Ubuntu VM with KVM support.
  The VM is deleted after the job. A writable build cache on the Mac is shared
  with later jobs on the same runner. See [Ubuntu / KVM Runners](#ubuntu--kvm-runners).

The macOS jobs cannot use the same VM isolation: Apple does not expose AVF
inside a macOS VM. Linux VMs can use nested virtualization on the supported Macs
listed below, which lets jobs run their own KVM guests.

## Requirements

- **Apple Silicon only.** This repo targets arm64 Macs (M-series); Intel/x64 is
  not supported.
- **macOS:** the macOS / AVF runners run on any reasonably current macOS. The
  Ubuntu / KVM runners need **macOS 15 (Sequoia)+ on M3/M4** — see that
  section's [requirements](#tart-requirements).
- The Mac must reach GitHub over outbound HTTPS on port 443.

GitHub documentation:

- [Add a self-hosted runner](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/adding-self-hosted-runners)
- [About self-hosted runners](https://docs.github.com/en/actions/reference/runners/self-hosted-runners)
- [Remove a self-hosted runner](https://docs.github.com/en/actions/hosting-your-own-runners/managing-self-hosted-runners/removing-self-hosted-runners)

---

# macOS / AVF Runners

Jobs run directly on the Mac and can use Apple's Virtualization.framework (AVF).
The setup script downloads the GitHub runner, registers it with your repository
or organization, and installs services to keep it running.

Each runner gets its own directory and home folder. You can also give each
runner a [separate macOS account](#separate-users-per-runner). Neither option
isolates jobs from the Mac; cleanup only removes the runner's `_work` directory.

## Scripts

- `bootstrap-gh-runners.sh`: downloads and registers the runners. With `--install-launchd`, it also creates their macOS service files (plists).
- `github-runner-wrapper.sh`: keeps the Mac awake, restarts a crashed runner and handles requests to stop it.
- `github-runner-cleanup.sh`: clears `_work` after each job. Setup copies it into each runner directory and enables it through `ACTIONS_RUNNER_HOOK_JOB_COMPLETED`.

## 1. Get A Registration Token

In your repository or organization:

1. Go to Settings -> Actions -> Runners.
2. Click New self-hosted runner.
3. Select macOS and the correct architecture for your Mac.
4. Note the repository or organization and copy the registration token.

Important:

- Do not commit tokens to git.
- If a token expires, generate a new one and rerun bootstrap.

## 2. Install The macOS Runners

Run this from the folder containing the scripts. Replace `your-org` and
`YOUR_REGISTRATION_TOKEN` with your values. This installs three runners that
start after reboot without anyone signing in (LaunchDaemon services):

```bash
sudo bash bootstrap-gh-runners.sh \
  --dir-prefix "$HOME/github-runner" \
  --count 3 \
  --org your-org \
  --token "YOUR_REGISTRATION_TOKEN" \
  --replace \
  --install-launchd \
  --launchd-scope daemon \
  --launchd-user "$USER"
```

Alternatively, to run only while your account is signed in, use LaunchAgent
services. This example registers runners for a repository:

```bash
bash bootstrap-gh-runners.sh \
  --dir-prefix "$HOME/github-runner" \
  --count 3 \
  --repo owner/repo \
  --token "YOUR_REGISTRATION_TOKEN" \
  --replace \
  --install-launchd \
  --launchd-scope agent
```

What this creates:

- `$HOME/github-runner-1`
- `$HOME/github-runner-2`
- `$HOME/github-runner-3`

Each service sets `HOME` to its runner's `.home` directory (for example,
`$HOME/github-runner-1/.home`). This keeps tools such as rustup from writing to
the same home folder at once. Homebrew, `/tmp`, keychains and system services
are still shared.

Common options:

- `--labels <csv>`: comma-separated custom labels (default `hvf`). Replaces the default custom labels, but not GitHub's automatic `self-hosted`, `macOS` and `ARM64` labels.
- `--runner-group <name>`: organization or enterprise runner group.
- `--name-prefix <prefix>`: prefix for runner names in GitHub.
- `--runner-user-prefix <prefix>`: create a separate non-admin macOS account for each runner. See [Separate users per runner](#separate-users-per-runner).
- `--token-file <path>`: read the registration token from a file instead of `--token`, keeping it out of shell history and the process list.
- `--replace`: stop and re-register existing runners without reinstalling their files. Replaces a runner with the same name in GitHub.
- `--force-recreate`: stop existing runners, delete their directories and reinstall. Also replaces runners with the same names in GitHub.
- `--install-launchd`: install or reload services for the requested runner count.
- `--uninstall-launchd`: stop and remove services for the requested runner count, then exit. No token, repository or organization is needed. Use `sudo` to also remove boot-time services.
- `--launchd-scope <agent|daemon>`: `agent` starts at sign-in; `daemon` starts at boot.
- `--launchd-user <user>`: account that runs boot-time services.
- `--launchd-dir <dir>`: folder for service files.
- `--launchd-label-prefix <prefix>`: prefix for service names (default `com.github.runner`).
- `--launch-agents-dir <dir>`: older name for `--launchd-dir`.
- `--version x.y.z`: version to download for a new installation. Existing runner files are reused, and the runner can still update itself.

Rerunning setup reuses configured runner directories unless you request
`--replace` or `--force-recreate`. For example, increasing `--count` from 2 to 3
adds the third runner. With `--install-launchd`, services for all three runners
are installed or reloaded, which can interrupt jobs. Setup also installs the
cleanup hook in each directory.

### Separate users per runner

Use `--runner-user-prefix` to create separate accounts. Setup starts
each runner automatically after reboot under its own user. No login is needed.
Run this from an administrator account:

```bash
sudo bash bootstrap-gh-runners.sh \
  --runner-user-prefix gha-macos \
  --count 3 \
  --org your-org \
  --token-file "$HOME/runner-registration-token" \
  --install-launchd \
  --launchd-scope daemon
```

This creates `gha-macos-1` through `gha-macos-3`. Each account has:

- A user folder at `/Users/gha-macos-N`, runner files in
  `/Users/gha-macos-N/actions-runner`, and logs in
  `/Users/gha-macos-N/.github-runner-logs`. Other runner users cannot access these.
- No administrator membership, a disabled password, and no interactive shell.
  The accounts are hidden from the login screen.
- Its own boot-time service, running as that account, **not root**.

Runner registration, installation and file updates run as that account too.
Shared service scripts are installed under the root-owned
`/Library/Application Support/github-runner-macos` directory, so the accounts
do not need access to the folder containing these scripts.

Do not combine this option with `--dir-prefix` or `--launchd-user`. Use the
standard service directory; custom `--launchd-dir` values are not supported in
this mode. Account names must start with a lowercase letter, contain only
lowercase letters, digits, `_` or `-`, and fit within 31 characters including
the `-N` suffix.

Rerunning setup reuses accounts it created and checks their ownership and
account settings. It refuses unrelated accounts or pre-existing homes rather
than taking them over. If account creation fails partway through, inspect the
partial account and home before retrying; bootstrap does not delete them.
Do not run two copies of the account setup at the same time.

**Switching existing runners:** follow the
[step-by-step migration guide](MIGRATE-TO-PER-USER-RUNNERS.md). It covers getting
the token, stopping the old runners, keeping their GitHub names, and checking
the new setup.

Install shared tools as an administrator and leave them read-only to runner
accounts. Keep writable caches and credentials per account. These accounts have
no automatic sudo access; existing host sudo policies must not grant it.
Jobs requiring a desktop session, an unlocked login keychain or macOS privacy
permissions may need additional setup. Run your AVF workflows under the new
accounts and check they succeed before replacing the old runners.

Separate users reduce cross-runner access and interference; they are **not a
sandbox**. System-wide resources remain shared, and state outside `_work`
persists between jobs on the same runner.

To remove the services:

```bash
sudo bash bootstrap-gh-runners.sh \
  --runner-user-prefix gha-macos \
  --count 3 \
  --launchd-scope daemon \
  --uninstall-launchd
```

Accounts, their files, and the shared service scripts are intentionally retained.
Remove runner registrations from GitHub separately.

Bootstrap regression tests use mocked macOS commands and do not create real
accounts or services: `bash tests/bootstrap-gh-runners.test.sh`.

## 3. Check The macOS Runners

LaunchDaemon mode:

```bash
for i in 1 2 3; do
  sudo launchctl print system/com.github.runner-${i} >/dev/null 2>&1 \
    && echo "runner-${i}: loaded" \
    || echo "runner-${i}: missing"
done
```

LaunchAgent mode:

```bash
launchctl list com.github.runner-1
launchctl list com.github.runner-2
launchctl list com.github.runner-3
```

Expected in runner terminal/logs after startup:

- Connected to GitHub
- Listening for Jobs

## Manage macOS Runners

LaunchDaemon mode:

```bash
# Status summary
for i in 1 2 3; do
  sudo launchctl print system/com.github.runner-${i} >/dev/null 2>&1 \
    && echo "runner-${i}: loaded" \
    || echo "runner-${i}: missing"
done

# Full status for one runner
sudo launchctl print system/com.github.runner-1

# Tail logs
tail -f ~/.github-runner-logs/runner-1-stdout.log
tail -f ~/.github-runner-logs/runner-1-stderr.log
tail -f ~/github-runner-1/.cleanup.log

# Tail all three stdout logs
tail -f ~/.github-runner-logs/runner-1-stdout.log \
        ~/.github-runner-logs/runner-2-stdout.log \
        ~/.github-runner-logs/runner-3-stdout.log

# Stop one runner
sudo launchctl bootout system/com.github.runner-1 || true

# Start one runner
sudo launchctl bootstrap system /Library/LaunchDaemons/com.github.runner-1.plist

# Restart all three runners
for i in 1 2 3; do
  sudo launchctl bootout system/com.github.runner-${i} || true
  sudo launchctl bootstrap system /Library/LaunchDaemons/com.github.runner-${i}.plist
done

# Stop all three
for i in 1 2 3; do
  sudo launchctl bootout system/com.github.runner-${i} || true
done

# Uninstall daemon services (manual)
for i in 1 2 3; do
  sudo launchctl bootout system/com.github.runner-${i} || true
  sudo rm -f /Library/LaunchDaemons/com.github.runner-${i}.plist
done

# Or let the script tear everything down (agent + daemon plists) for 1..N:
sudo bash bootstrap-gh-runners.sh --dir-prefix "$HOME/github-runner" --count 3 --uninstall-launchd
```

LaunchAgent mode:

```bash
for i in 1 2 3; do
  launchctl unload ~/Library/LaunchAgents/com.github.runner-${i}.plist || true
  launchctl load   ~/Library/LaunchAgents/com.github.runner-${i}.plist
done
```

Notes:

- LaunchDaemon services start after reboot without anyone signing in.
- LaunchAgent services start when their user signs in.
- After five failures within ten minutes, the wrapper waits three minutes before
  retrying. This prevents constant restarts when a runner is broken.
- These service environment variables control the retry limits:
  `GH_WRAPPER_FAILURE_THRESHOLD`, `GH_WRAPPER_FAILURE_WINDOW_SEC`,
  `GH_WRAPPER_FAILURE_COOLDOWN_SEC`.

To remove a runner's GitHub registration, open **Settings -> Actions -> Runners**
in GitHub and select the runner's removal option. If you still have access to
the Mac, follow the removal command GitHub displays.

---

# Ubuntu / KVM Runners

Each job runs in a fresh Ubuntu 24.04 VM managed by [Tart](https://tart.run).
The VM is copied from a prepared image (called the golden image) and deleted
after the job. Nested virtualization gives the job access to `/dev/kvm`, so it
can run its own ARM64 VMs.

These register as separate runners. You can use them alongside the macOS runners.

## Scripts

- `bootstrap-tart-runners.sh`: prepares the image if needed; with `--install-launchd`, installs runner services and the daily image updater.
- `tart-install-image-updater.sh`: installs daily image updates without changing runner services.
- `tart-update-image.sh`: updates Ubuntu packages and the GitHub runner in a verified image clone.
- `tart-bake-ubuntu.sh`: prepares the Ubuntu 24.04 image with the runner and KVM support.
- `tart-runner-loop.sh`: repeatedly creates a VM, runs one job and deletes the VM.
- `tart-github-app-token.sh`: gets short-lived runner registration tokens using a GitHub App.
- `tart-common.sh`: shared helpers/defaults sourced by the above (not run directly).

## How it works

```mermaid
flowchart LR
  G[Original Ubuntu image] --> A[Image used for new jobs]
  U[Daily package and runner update] -->|use updated image if checks pass| A
  A -->|clone| B[Ephemeral VM]
    B -->|tart run --nested| C[Boot Ubuntu 24.04]
    C -->|get token using GitHub App| D[config.sh --ephemeral]
    D -->|run.sh| E[Run ONE job]
    E -->|tart stop + delete| F[Destroy VM]
    F -->|loop| A
```

Each runner process handles one job at a time. Setup installs one service per
runner, so `--count 3` lets three jobs run at once.

## Tart Requirements

- **Hardware/OS:** Apple Silicon **M3 or M4** running **macOS 15 (Sequoia) or
  later**. Nested virtualization requires this combination and works only in
  **Linux guests**. See the [Tart FAQ](https://tart.run/faq/#nested-virtualization-support).
  KVM can run ARM64 guests, not x86 guests.
- **Tools on the Mac:** [`tart`](https://tart.run), `curl`, `openssl`, `jq`,
  `sshpass` (used during image setup), and `ssh`/`ssh-keygen`.

  ```bash
  brew install cirruslabs/cli/tart jq
  brew install hudochenkov/sshpass/sshpass   # or any sshpass formula
  ```

- A **GitHub App** to register runners (see below). No personal access token is
  needed, and registration tokens are not saved to disk.

## First Install

Run commands from the folder containing these scripts on the Mac. Do not move
that folder after setup: the services run scripts from that location. To update
an existing installation, use
[Update Ubuntu Packages And GitHub Runner](#update-ubuntu-packages-and-github-runner), not repeat bootstrap.

### 1. Create the GitHub App

The Mac uses a GitHub App's private key to get a short-lived registration token
whenever it starts a runner. The private key stays on the Mac.

1. Go to **GitHub → Settings**:
   - For a **repository/personal** target: your user **Settings → Developer
     settings → GitHub Apps → New GitHub App**.
   - For an **organization** target: **Org Settings → Developer settings →
     GitHub Apps → New GitHub App** (so the org owns the App).
2. Fill in:
   - **GitHub App name:** anything unique, e.g. `my-tart-runners`.
   - **Homepage URL:** anything (e.g. your repo URL).
   - **Webhook:** untick **Active** (we don't need webhooks).
3. Set **Permissions**:
   - **Repository target:** Repository permissions → **Administration: Read &
     write** (required to create runner registration tokens).
   - **Organization target:** Organization permissions → **Self-hosted runners:
     Read & write**.
4. Under **Where can this GitHub App be installed?** choose **Only on this
   account**.
5. Click **Create GitHub App**.
6. On the App's page, note the **App ID** (top of the page).
7. Scroll to **Private keys → Generate a private key**. This downloads a
   `.pem` file. **Store it securely** (e.g. `~/.config/github-runner-tart/app.private-key.pem`,
   `chmod 600`). Never commit it.
8. Click **Install App** (left sidebar) → install it on the account, and select
   the repository (or **All repositories**) / organization you want runners for.

You now have an **App ID** and a **private key `.pem`** — that's all the host
needs.

### 2. Prepare the patched kernel packages

Creating the image requires patched kernel and header packages matching
`debs/linux*7.0.0-28*vmid5*.deb`. Setup does not download or build them for you.

The [kernel build helper](tart-build-kernel.sh) builds patched packages in a
separate `kernel-builder` VM and writes them to `./debs`:

```bash
bash tart-build-kernel.sh
find ./debs -maxdepth 1 -name 'linux*7.0.0-28*vmid5*.deb' -print
```

**Known setup problem:** the image setup script requires patched kernel `7.0.0-28`, but the build
helper may build a different version. If the command above lists no matching
packages, first-time setup will fail. The scripts need to agree on the kernel
version. Routine updates to an existing image do not need these packages.

### 3. Install The Ubuntu Runners

Replace the organization, App ID and private-key path with your values. This
installs three runners that start after reboot without anyone signing in:

```bash
sudo bash bootstrap-tart-runners.sh \
  --count 3 \
  --org your-org \
  --app-id 123456 \
  --private-key "$HOME/.config/github-runner-tart/app.private-key.pem" \
  --cpus 2 \
  --memory-mb 4096 \
  --disk-gb 50 \
  --install-launchd \
  --launchd-scope daemon \
  --launchd-user "$USER"
```

For a repository, replace `--org your-org` with `--repo owner/repo`.

Setup reuses an existing image. On a fresh install it creates `gha-ubuntu-kvm`,
installs the runner, LLVM/Clang 18 tools, QEMU, build-essential and the local
patched kernel. It generates a dedicated SSH key under
`~/.config/github-runner-tart/` and disables password SSH after initial access
with the base image's `admin`/`admin` credentials. Setup checks KVM **before**
installing the patched kernel; it does not validate that kernel after reboot.
Confirm a real workflow succeeds using [Check Ubuntu Runners](#check-ubuntu-runners).

With `--install-launchd`, setup also installs the daily image updater.
Use `--no-image-refresh` to skip installing it; this does not disable an updater
that is already installed.

To rebuild an existing image, rerun your bootstrap command with `--rebuild-image`.
Wait until jobs finish first: bootstrap can restart runner services and interrupt
jobs. Do not replace the image by running the bake script directly; runners may
keep using the previous image.

## Update Ubuntu Packages And GitHub Runner

Run as the account that owns the Tart VMs, **without sudo**. No bootstrap,
GitHub App credentials, full rebake or local kernel packages are needed:

```bash
bash tart-update-image.sh
```

The updater copies the current image, upgrades its Ubuntu packages using APT,
and installs the latest GitHub runner if needed. It verifies the runner download
against its published checksum. Package updates are checked even if the runner
is already current.

Before using a changed image for new jobs, it reboots the VM and checks the runner
version, KVM support and that the kernel has not changed. If a check fails, jobs
keep using the previous image. If nothing changed, the extra copy is deleted.
These checks do not replace running a real workflow.

Running jobs are not affected. The Mac needs enough memory and disk for one extra
VM during the update. Old images stay on disk until you delete them.

You still need to handle these separately:

- **Kernel updates, including security fixes:** the updater keeps the patched kernel unchanged.
- **Changing Ubuntu or LLVM versions:** it does not upgrade Ubuntu to another release or replace LLVM 18 with a newer major version.
- **Mac software and manually installed guest tools:** it does not update macOS, Homebrew, Tart or guest software installed without APT.
- **Skipped packages:** packages marked "hold" are left alone. Updates that would remove another package are also skipped; check the logs for these.

## Enable Daily Ubuntu Package And GitHub Runner Updates

If your runners are already installed but you did not enable automatic updates,
open Terminal on the Mac that runs the VMs. Sign in as the account that owns
those VMs, then use `cd` to open the folder containing these scripts. Run:

```bash
sudo bash tart-install-image-updater.sh --launchd-user "$USER"
```

That is all you need to install the scheduled updater. **Do not rerun bootstrap.**
No GitHub App credentials are needed, and runner services are not restarted.
The updater runs immediately, then every 24 hours while the Mac is awake. It
starts again after reboot without anyone signing in. It updates Ubuntu packages
and the GitHub runner using the same checks as the manual update command above.

If you previously installed the updater before the scripts were renamed, run
the same command again to fix the saved script path. Its service label and log
filenames still contain `image-refresh`.

For older runners that do not yet support updated images, also
[restart the runners once](#restart-runners), after their jobs finish.
Their logs should then show `Cloning <selected-image> -> ...` using the image
listed under [Check Whether Updates Worked](#check-whether-updates-worked).

## Check Whether Updates Worked

Run these commands on the Mac, signed in as the account that owns the VMs:

```bash
# Check the scheduled updater.
sudo launchctl print system/com.github.tart-runner-image-refresh

# Read the update logs.
cat "$HOME/.github-runner-logs/tart-image-refresh-stdout.log"
cat "$HOME/.github-runner-logs/tart-image-refresh-stderr.log"
```

Look for `Promoted updated guest packages and runner` or
`guest packages are current; no image promoted` in the logs. Errors explain why
an update failed. Normal package-install output also goes into the stderr log;
text in that file does not by itself mean failure. There are no email or other
failure notifications.

To see which image new jobs will use:

```bash
image_file="$HOME/.config/github-runner-tart/images/gha-ubuntu-kvm.current"
if [[ -f "$image_file" ]]; then
  cat "$image_file"
else
  printf '%s\n' gha-ubuntu-kvm
fi
```

Jobs already running keep their existing VM. Confirm a real workflow succeeds
after an update; an installed service alone does not prove the runners work.

## Undo An Image Update

Use this only if an updated image causes problems.

1. Stop automatic updates so they cannot immediately replace the older image:

   ```bash
   sudo launchctl bootout system/com.github.tart-runner-image-refresh
   ```

2. Prevent new jobs from starting, let current jobs finish, then
   [stop the runners](#stop-runners).
3. Run `tart list` to see the saved images. Choose one that worked before the
   update. In the block below, set `rollback_image` to its name. The default
   shown, `gha-ubuntu-kvm`, is the original image, not necessarily the most
   recent working one.
4. From the folder containing these scripts, run this as the account that owns
   the VMs, without sudo:

   ```bash
   bash <<'ROLLBACK'
   set -euo pipefail
   source ./tart-common.sh
   rollback_image="gha-ubuntu-kvm"
   state_dir="$TART_CONFIG_DIR/images"
   lock_dir="$state_dir/$TART_GOLDEN_IMAGE.lock"
   tart get "$rollback_image" >/dev/null
   mkdir "$lock_dir"
   trap 'rm -f "$state_dir/$TART_GOLDEN_IMAGE.current.tmp"; rmdir "$lock_dir"' EXIT
   printf '%s\n' "$rollback_image" > "$state_dir/$TART_GOLDEN_IMAGE.current.tmp"
   mv "$state_dir/$TART_GOLDEN_IMAGE.current.tmp" "$state_dir/$TART_GOLDEN_IMAGE.current"
   ROLLBACK
   ```

   If `mkdir` reports that the `.lock` folder already exists, stop. An image build
   or update may still be running. Do not delete the lock while either is running.

5. [Start the runners again](#restart-runners) and check that a workflow succeeds.
   Keep automatic updates stopped until the problem is fixed. To enable them
   again, rerun the daily-update installation command; this immediately starts
   another update check.

Old images are not deleted automatically. Once you have confirmed a replacement
works, use `tart delete <image-name>` to remove images you no longer need.
Keep the original image, the image chosen for new jobs, and any image still in
use.

## Reference

### Workflow Labels

The only custom label by default is `kvm`. GitHub automatically adds
`self-hosted`, `Linux`, and `ARM64`; neither bootstrap disables these default
labels. Labels are case-insensitive. Request the OS, architecture, and capability
explicitly in workflows:

```yaml
jobs:
  build:
    runs-on: [self-hosted, Linux, ARM64, kvm]
```

GitHub chooses a runner that has **all the labels requested by the job**. Extra
labels on a runner do not prevent it from accepting jobs: a job asking only for
`self-hosted` or `Linux` can still run here. Include `ARM64` and `kvm` to require
both ARM64 hardware and KVM support. Labels choose runners; they do not control
who is allowed to use them.

Do not add GitHub-hosted image labels such as `ubuntu-24.04` to these runners.
A bare `runs-on: ubuntu-24.04` can otherwise match an ARM64 Tart runner instead
of the intended GitHub-hosted x64 environment. The guest remains Ubuntu 24.04;
removing that label does not change its OS or installed tools.

### Runner Setup Options

Common options for `bash bootstrap-tart-runners.sh` (run with `--help` for the full list):

- `--count <N>`: maximum number of jobs that can run at once.
- `--golden-image <name>`: golden image name (default `gha-ubuntu-kvm`).
- `--base-image <ref>`: Ubuntu image to start from (default `ghcr.io/cirruslabs/ubuntu:latest`).
- `--runner-version <x.y.z>`: runner version to install when creating the image. Later image updates install the latest version, and the runner can also update itself.
- `--cpus <n>`: set guest vCPU count in the baked image.
- `--memory-mb <mb>`: set guest RAM in MB in the baked image.
- `--disk-gb <gb>`: set guest disk size in GB in the baked image.
- `--labels <csv>`: comma-separated custom labels (default `kvm`). Keep `kvm` when adding labels for KVM jobs. GitHub's automatic labels are unchanged. This option overrides `TART_RUNNER_LABELS` if set.
- `--name-prefix <prefix>`: runner name prefix (default `tart-ubuntu`).
- `--rebuild-image`: force a rebuild of the golden image.
- `--install-launchd`: install or reload runner services and the daily image updater.
- `--no-image-refresh`: skip installing the image updater; does not remove an existing updater.
- `--launchd-scope <agent|daemon>`: `agent` starts at sign-in; `daemon` starts at boot.
- `--launchd-user <user>`: account that runs boot-time services.
- `--launchd-dir <dir>`: folder for service files.
- `--launchd-label-prefix <p>`: prefix for service names (default `com.github.tart-runner`).

### Automatic Failure Recovery

- SSH connections time out if a VM stops responding, rather than leaving the runner stuck.
- The runner cleans up leftover `tart run` processes on the Mac.
- After three failures within ten minutes, a runner waits three minutes before retrying.

### Build Cache

VMs are deleted after each job, but build caches can be reused. Each runner
shares its own cache folder on the Mac with its VMs using virtio-fs:

- On the Mac: `~/.cache/github-runner-tart/runner-<N>/`.
- Inside the VM: `/var/cache/ci/ci-cache/`. If the shared folder cannot be mounted,
  the job still runs, but it cannot reuse that cache.
- For [sccache](https://github.com/mozilla/sccache): the runner sets
  `SCCACHE_DIR=/var/cache/ci/ci-cache/sccache` and `SCCACHE_CACHE_SIZE`. Your
  workflow must still enable sccache. Cached files stay on the Mac; they are not
  uploaded to GitHub's cache service.

This does not replace `Swatinem/rust-cache` or share `CARGO_HOME` and `target`
directories. Each runner has its own cache folder, so simultaneous jobs on
different runners do not write to the same cache. They also cannot reuse each
other's cached files.

The default sccache size limit is `20G` per runner (`TART_CACHE_MAX_SIZE`).
`TART_CACHE_DIR` changes the parent cache folder; rerun service installation to
apply a changed path to the services.

## Check Ubuntu Runners

For services that start at boot (LaunchDaemons):

```bash
# Status (all configured Tart runner daemons)
for i in 1 2 3; do
  sudo launchctl print system/com.github.tart-runner-${i} >/dev/null 2>&1 \
    && echo "runner-${i}: loaded" \
    || echo "runner-${i}: missing"
done

# Full status dump for one daemon
sudo launchctl print system/com.github.tart-runner-1

# Tail stdout/stderr for one runner
tail -f ~/.github-runner-logs/tart-runner-1-stdout.log
tail -f ~/.github-runner-logs/tart-runner-1-stderr.log

# Tail all runner stdout logs together
tail -f ~/.github-runner-logs/tart-runner-1-stdout.log \
        ~/.github-runner-logs/tart-runner-2-stdout.log \
        ~/.github-runner-logs/tart-runner-3-stdout.log

# Show current VM state (golden + active clones)
tart list | grep -E 'gha-ubuntu-kvm|gha-ubuntu-kvm-runner-'
```

LaunchAgent mode:

```bash
launchctl list com.github.tart-runner-1
launchctl list com.github.tart-runner-2
```

You should see clone → boot → "Listening for Jobs", followed by teardown after
a job completes. In **GitHub → Settings → Actions → Runners**, a runner appears
while waiting for or processing a job and deregisters after its single job.
Run a workflow with `[self-hosted, Linux, ARM64, kvm]` and confirm it succeeds;
service status alone does not verify a usable runner.

## Run A Runner Manually

Useful for debugging:

```bash
bash tart-runner-loop.sh \
  --app-id 123456 \
  --private-key "$HOME/.config/github-runner-tart/app.private-key.pem" \
  --repo owner/repo \
  --golden-image gha-ubuntu-kvm \
  --index 1
```

## Manage Ubuntu Runners

Use only the commands for the operation you need. The examples below use three
boot-time runners or two runners that start at sign-in. Adjust the count if yours
differs. Stopping or restarting a runner can interrupt its job: let jobs finish
and prevent new assignments first. The image updater is a separate service;
restarting runners does not restart it.

### Restart Runners

Daemons (example: three runners):

```bash
for i in 1 2 3; do
  sudo launchctl bootout system/com.github.tart-runner-${i} || true
  sudo launchctl bootstrap system /Library/LaunchDaemons/com.github.tart-runner-${i}.plist
done
```

Agents (example: two runners, run as their owner):

```bash
for i in 1 2; do
  launchctl unload "$HOME/Library/LaunchAgents/com.github.tart-runner-${i}.plist" || true
  launchctl load "$HOME/Library/LaunchAgents/com.github.tart-runner-${i}.plist"
done
```

### Stop Runners

Services that start at boot:

```bash
for i in 1 2 3; do
  sudo launchctl bootout system/com.github.tart-runner-${i}
done
```

Services that start at sign-in (run as their owner):

```bash
for i in 1 2; do
  launchctl unload "$HOME/Library/LaunchAgents/com.github.tart-runner-${i}.plist"
done
```

This keeps the service files. Use [Restart Runners](#restart-runners) to start
them again. The image updater keeps running unless you stop it separately; see
[Undo An Image Update](#undo-an-image-update).

### Remove Services

Daemons:

```bash
sudo launchctl bootout system/com.github.tart-runner-image-refresh || true
sudo rm -f /Library/LaunchDaemons/com.github.tart-runner-image-refresh.plist
for i in 1 2 3; do
  sudo launchctl bootout system/com.github.tart-runner-${i} || true
  sudo rm -f /Library/LaunchDaemons/com.github.tart-runner-${i}.plist
done
```

Agents:

```bash
launchctl unload "$HOME/Library/LaunchAgents/com.github.tart-runner-image-refresh.plist" || true
rm -f "$HOME/Library/LaunchAgents/com.github.tart-runner-image-refresh.plist"
for i in 1 2; do
  launchctl unload ~/Library/LaunchAgents/com.github.tart-runner-${i}.plist || true
  rm -f ~/Library/LaunchAgents/com.github.tart-runner-${i}.plist
done
```

These commands remove services, not VM images, SSH keys, GitHub App keys or build
caches. To remove the VMs too, first stop all runners and the image updater.
Then run `tart list` as their owner and delete this setup's images and leftover
job VMs individually. Only remove its `.current` file after the services have
stopped. Do not delete images or files used by other runners.

Each runner is registered for one job (`--ephemeral`) and removes its GitHub
registration afterward. You normally do not need to remove it in GitHub.

## Troubleshooting

- **Save logs when a runner fails:**

  ```bash
  # Watch all 3 runners; on first error marker it auto-captures and exits.
  ./monitor-tart-debug.sh auto all 200
  
  # Same, but only for runner 1.
  ./monitor-tart-debug.sh auto 1 200
  ```

  The last number (`200`) is the number of lines per log section included in
  the generated snapshot file. Use a larger value for more context, or a
  smaller value for shorter snapshots.

  To watch logs continuously or save them immediately:

  ```bash
  # Continuous live stream (manual Ctrl+C)
  ./monitor-tart-debug.sh watch all

  # One-shot dump right now (returns immediately)
  ./monitor-tart-debug.sh snapshot all 200
  ```

- **`VZErrorDomain Code=1` / "The virtual machine stopped unexpectedly":** this means the guest process crashed at the Apple Virtualization layer (host-side), not just a workflow failure inside Linux.
  To collect more detailed logs and keep failed VMs for inspection, reinstall
  the services with the following command. Replace the organization, App ID and
  key path with your values, and wait for jobs to finish first:

  ```bash
  TART_RUNNER_DEBUG=1 \
  TART_KEEP_FAILED_VM=1 \
  TART_VM_LOG_LOOKBACK_MINUTES=15 \
  sudo bash bootstrap-tart-runners.sh \
    --count 3 \
    --org your-org \
    --app-id 123456 \
    --private-key "$HOME/.config/github-runner-tart/app.private-key.pem" \
    --install-launchd \
    --launchd-scope daemon \
    --launchd-user "$USER"
  ```

  Then inspect:
  - `~/.github-runner-logs/tart-runner-<n>-stdout.log` (runner activity)
  - `~/.github-runner-logs/tart-runner-<n>-vm-*.log` (raw `tart run` output, includes VZ errors)
  - `~/.github-runner-logs/tart-runner-<n>-vm-diagnostics.log` (host `log show` extract for Tart/Virtualization)
  - `~/.github-runner-logs/tart-runner-<n>-trace.log` (shell commands run with debug logging enabled)

  With `TART_KEEP_FAILED_VM=1`, failed clones are not deleted, so you can inspect their state with `tart list` and `tart get <vm-name>`.

- **`/dev/kvm` missing / bake fails at `kvm-ok`:** the host isn't M3/M4 on
  macOS 15+, or Tart was started without `--nested`. Nested virt is not
  supported on M1/M2.
- **Cannot get a registration token:** check the App ID, that the `.pem` matches the App,
  that the App is **installed** on the target repo/org, and that it has the
  Administration / Self-hosted runners write permission.
- **VM never gets an IP address or SSH does not connect:** check that the image
  appears in `tart list`. If boot is slow, increase `TART_BOOT_TIMEOUT`.

---

For other failures, check the logs in `~/.github-runner-logs/`.
