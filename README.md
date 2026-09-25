# bioinformatico-ostree

My Fedora Kinoite, as a bootable container image. GitHub Actions rebuilds it on every push and
daily, publishing to `ghcr.io/prossouw-bioinformatico/bioinformatico-ostree`. Installed machines
pull the new image through Discover's updates or `sudo bootc upgrade`.

## What's in it

| Where | What |
|---|---|
| Image (`Containerfile`) | 1Password + 1Password CLI, Chrome, Edge, VS Code, git, zsh, tmux, htop, bmon, gource, virt-manager + libvirt/qemu, Handy |
| Flatpaks (`system_files/usr/share/bioinformatico/flatpaks.list`) | GitKraken, Obsidian, Ferdium, LocalSend, Podman Desktop, FreeFileSync. Installed by `bioinformatico-flatpaks.service` on boot whenever the list changes |
| Per user (`bioinformatico-user-setup`) | libvirt group membership, `dev` toolbox with gcc/make/gdb |

1Password, its CLI and the browsers are in the image (not Flatpaks) so CLI integration, browser
unlock and the SSH agent work. Their `/opt` contents are moved to `/usr/lib/opt` and linked back
at boot, and 1Password's groups have fixed GIDs (`usr/lib/sysusers.d/onepassword.conf`).

To add a package: add it to a `dnf-install.sh` line in the `Containerfile` (or a new `RUN` line for a new
source). Handy is pinned by `HANDY_VERSION`. Third-party repos are disabled at the end of the
build (`build_files/configure.sh`), so add any new one to that list too. To add a Flatpak: add its ID to
`flatpaks.list`. Push, and machines get it on their next update.

## Installing

**Fresh install from ISO:** `make iso` builds `output/bootiso/bioinformatico-ostree-44.iso` from a local build
(`make iso-remote` uses the published image instead). The installer only asks about the disk. Plasma Setup
creates your user on first boot, and the installed system already tracks the GHCR image.

**Switching an existing Kinoite install:**

```
sudo bootc switch ghcr.io/prossouw-bioinformatico/bioinformatico-ostree:latest
systemctl reboot
```

Then, once, as your user: `bioinformatico-user-setup`.

The GHCR package is private by default. Either make it public (GitHub → Packages →
bioinformatico-ostree → Package settings) or put a pull token in `/etc/ostree/auth.json`.

## Updates and rollback

```
sudo bootc upgrade        # fetch and stage the latest image, applied on reboot
sudo bootc rollback       # go back to the previous image
bootc status
```

## Signing (optional, recommended)

1. `make cosign-keys`
2. Add the contents of `cosign.key` as the repo secret `SIGNING_SECRET` (and its password as
   `COSIGN_PASSWORD`). Commit `cosign.pub` and never commit `cosign.key`.
3. Push. CI signs each image, and the image now carries a policy that rejects unsigned updates.
4. On each machine, switch once more so the signature check is enforced:
   `sudo bootc switch --enforce-container-sigpolicy ghcr.io/prossouw-bioinformatico/bioinformatico-ostree:latest`

## Local build

```
make build   # rootless podman, tags localhost/bioinformatico-ostree:latest
make lint    # shellcheck
```

Every build step is its own cached layer, downloaded RPMs are kept in podman's build cache,
and `make iso` keeps bootc-image-builder's caches in `cache/`. If a build fails (e.g. on a
network error), run the same command again and it resumes from the failed step.
`make build-fresh` ignores the layer cache; `make clean-cache` clears all caches.

`make build` and `make iso` start with a DNS check (`check-dns` / `check-dns-root`) that resolves
the hosts they need from inside a container, so a network problem fails in seconds.

Bump Fedora with `FEDORA_VERSION` (Makefile, Containerfile default, and the workflow `env`).
