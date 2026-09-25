#!/usr/bin/bash
# Install packages as one image layer: dnf install, move anything under /opt into the image,
# and clean up so the layer carries no build leftovers. Used by each package RUN in the
# Containerfile, so a failed download only reruns that one layer.
set -xeuo pipefail

# /opt is a symlink to /var/opt, and /var isn't part of the deployed image.
mkdir -p /var/opt

# keepcache: downloaded RPMs stay in the /var/cache/libdnf5 cache mount, so a retry after a
# network failure only fetches what's still missing.
dnf install -y --setopt=keepcache=True --setopt=retries=10 --setopt=timeout=60 "$@"

# Move /var/opt/* to /usr/lib/opt and have systemd link it back at boot.
mkdir -p /usr/lib/opt
for dir in /var/opt/*; do
  [[ -e $dir ]] || continue
  name=${dir##*/}
  mv "$dir" "/usr/lib/opt/$name"
  echo "L+ /var/opt/$name - - - - /usr/lib/opt/$name" > "/usr/lib/tmpfiles.d/opt-$name.conf"
done

# (/var/cache/libdnf5 is the cache mount, so it's left alone)
rm -rf /var/opt /var/log/* /var/lib/dnf /var/lib/rpm-state /tmp/* /run/dnf /run/gluster /run/selinux-policy
find /var/cache -mindepth 1 -maxdepth 1 ! -name libdnf5 -exec rm -rf {} +
