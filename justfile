default: check

format:
    shfmt -w -i 4 -ci tart-install-image-updater.sh tart-update-image.sh tests/tart-image-refresh.test.sh

format-check:
    shfmt -d -i 4 -ci tart-install-image-updater.sh tart-update-image.sh tests/tart-image-refresh.test.sh
    git diff --check

syntax:
    bash -n bootstrap-tart-runners.sh tart-common.sh tart-runner-loop.sh tart-install-image-updater.sh tart-update-image.sh tests/tart-image-refresh.test.sh

lint:
    shellcheck -S warning bootstrap-tart-runners.sh tart-runner-loop.sh tart-install-image-updater.sh tart-update-image.sh tests/tart-image-refresh.test.sh
    shellcheck -S warning -e SC2064 tart-common.sh

test-image-refresh:
    bash tests/tart-image-refresh.test.sh

test:
    bash tests/bootstrap-gh-runners.test.sh
    bash tests/tart-image-refresh.test.sh

check: format-check syntax lint test