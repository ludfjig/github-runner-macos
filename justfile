default: check

format:
    shfmt -w -i 4 -ci tart-install-image-updater.sh tart-update-image.sh tart-configure-runners.sh tart-guest-memory.sh tests/tart-image-refresh.test.sh tests/tart-configure-runners.test.sh tests/tart-guest-memory.test.sh

format-check:
    shfmt -d -i 4 -ci tart-install-image-updater.sh tart-update-image.sh tart-configure-runners.sh tart-guest-memory.sh tests/tart-image-refresh.test.sh tests/tart-configure-runners.test.sh tests/tart-guest-memory.test.sh
    git diff --check

syntax:
    for file in bootstrap-tart-runners.sh tart-common.sh tart-runner-loop.sh tart-bake-ubuntu.sh tart-install-image-updater.sh tart-update-image.sh tart-configure-runners.sh tart-guest-memory.sh tests/tart-image-refresh.test.sh tests/tart-configure-runners.test.sh tests/tart-guest-memory.test.sh tests/tart-image-retention.test.sh; do bash -n "$file" || exit; done

lint:
    shellcheck -S warning bootstrap-tart-runners.sh tart-runner-loop.sh tart-bake-ubuntu.sh tart-install-image-updater.sh tart-update-image.sh tart-configure-runners.sh tart-guest-memory.sh tests/tart-image-refresh.test.sh tests/tart-configure-runners.test.sh tests/tart-guest-memory.test.sh tests/tart-image-retention.test.sh
    shellcheck -S warning -e SC2064 tart-common.sh

test-image-refresh:
    bash tests/tart-image-refresh.test.sh

test:
    bash tests/bootstrap-gh-runners.test.sh
    bash tests/tart-image-refresh.test.sh
    bash tests/tart-configure-runners.test.sh
    bash tests/tart-guest-memory.test.sh
    bash tests/tart-image-retention.test.sh

check: format-check syntax lint test