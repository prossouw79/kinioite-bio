ARG FEDORA_VERSION=44

# Layers are ordered from least to most frequently changed, and each package group is its
# own layer: a failed download only reruns that layer, and editing config or the Flatpak
# list never reinstalls packages.

# Only the install helper, so editing other build scripts doesn't invalidate package layers
FROM scratch AS helpers
COPY build_files/dnf-install.sh /

# The whole repo (minus .containerignore) for the final configure step
FROM scratch AS config
COPY . /

FROM quay.io/fedora-ostree-desktops/kinoite:${FEDORA_VERSION}

### Third-party repos, their signing keys, and 1Password's fixed-GID groups (which must
# exist before its scriptlets run, or they groupadd with random GIDs)
COPY system_files/etc/yum.repos.d/ /etc/yum.repos.d/
COPY system_files/usr/lib/sysusers.d/ /usr/lib/sysusers.d/
RUN set -eux; \
    for key in microsoft.asc=https://packages.microsoft.com/keys/microsoft.asc \
               google-linux.pub=https://dl.google.com/linux/linux_signing_key.pub \
               1password.asc=https://downloads.1password.com/linux/keys/1password.asc; do \
      curl -fsSL --retry 5 --retry-all-errors -o "/etc/pki/rpm-gpg/${key%%=*}" "${key#*=}"; \
    done; \
    systemd-sysusers /usr/lib/sysusers.d/onepassword.conf

### Packages, one layer per source
RUN --mount=type=bind,from=helpers,source=/,target=/h --mount=type=cache,dst=/var/cache/libdnf5 \
    /h/dnf-install.sh git zsh tmux htop bmon gource virt-manager libvirt qemu-kvm

RUN --mount=type=bind,from=helpers,source=/,target=/h --mount=type=cache,dst=/var/cache/libdnf5 \
    /h/dnf-install.sh 1password 1password-cli

RUN --mount=type=bind,from=helpers,source=/,target=/h --mount=type=cache,dst=/var/cache/libdnf5 \
    /h/dnf-install.sh google-chrome-stable

RUN --mount=type=bind,from=helpers,source=/,target=/h --mount=type=cache,dst=/var/cache/libdnf5 \
    /h/dnf-install.sh microsoft-edge-stable

RUN --mount=type=bind,from=helpers,source=/,target=/h --mount=type=cache,dst=/var/cache/libdnf5 \
    /h/dnf-install.sh code

# Handy isn't in any repo; bump this to update it (https://github.com/cjpais/Handy/releases)
ARG HANDY_VERSION=0.9.7
RUN --mount=type=bind,from=helpers,source=/,target=/h --mount=type=cache,dst=/var/cache/libdnf5 \
    /h/dnf-install.sh "https://github.com/cjpais/Handy/releases/download/v${HANDY_VERSION}/Handy-${HANDY_VERSION}-1.x86_64.rpm"

### This repo's files and configuration (cheap; reruns whenever the repo changes)
COPY system_files /

# Users allowed to approve 1Password CLI / SSH agent requests (space-separated)
ARG ONEPASSWORD_USERS=pieter
ARG IMAGE_REF=ghcr.io/prossouw-bioinformatico/bioinformatico-ostree
RUN --mount=type=bind,from=config,source=/,target=/ctx \
    ONEPASSWORD_USERS="${ONEPASSWORD_USERS}" IMAGE_REF="${IMAGE_REF}" /ctx/build_files/configure.sh

RUN bootc container lint
