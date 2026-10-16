# System test image (layer 2, slice 3 criterion 12): a minimal Ubuntu with
# only sudo, curl and ca-certificates added and a non-root user `tester`
# with passwordless sudo. No git: bootstrap.sh must install it.
#
# Built and run by `tests/run.sh system`; see run-in-container.sh for the
# contract.

FROM ubuntu:24.04

RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        sudo curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --shell /bin/bash tester \
    && printf 'tester ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/tester \
    && chmod 0440 /etc/sudoers.d/tester

USER tester
WORKDIR /home/tester
