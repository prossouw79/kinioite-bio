FEDORA_VERSION ?= 44
IMAGE_REF      ?= ghcr.io/prossouw-bioinformatico/bioinformatico-ostree
LOCAL_IMAGE    ?= localhost/bioinformatico-ostree:latest
BIB_IMAGE      ?= quay.io/centos-bootc/bootc-image-builder:latest
OUTPUT         ?= output
CACHE          ?= cache

# newer: rebuild everything when Kinoite publishes a new base, otherwise reuse cached layers.
# Use PULL=never to retry against exactly the base you already have.
PULL     ?= newer
# missing: don't hit the network for the builder image once it's present.
BIB_PULL ?= missing

# Hosts each stage needs. check-dns resolves them inside a container using the same network
# setup as the real step, so a DNS/firewall problem fails in seconds instead of mid-build.
BUILD_HOSTS ?= mirrors.fedoraproject.org packages.microsoft.com dl.google.com \
	downloads.1password.com github.com
ISO_HOSTS   ?= mirrors.fedoraproject.org

.PHONY: help check-dns check-dns-root build build-fresh lint iso iso-remote cosign-keys clean clean-cache

help:
	@echo "make check-dns    check DNS from a rootless container (runs before build)"
	@echo "make check-dns-root  check DNS the way the ISO builder sees it (runs before iso)"
	@echo "make build        build the image locally (rootless podman, cached layers)"
	@echo "make build-fresh  rebuild the image with no layer cache"
	@echo "make lint         shellcheck the scripts"
	@echo "make iso          build an installer ISO from the local image (sudo)"
	@echo "make iso-remote   build an installer ISO from $(IMAGE_REF):latest (sudo)"
	@echo "make cosign-keys  generate the image signing key pair"
	@echo "make clean        remove $(OUTPUT)/"
	@echo "make clean-cache  remove the ISO builder caches in $(CACHE)/ and podman's build cache"
	@echo
	@echo "Every target is safe to re-run after a failure: finished image layers, downloaded"
	@echo "RPMs and the ISO builder's store are all reused."

# $(call dns_check,<podman command>,<image>,<hosts>)
define dns_check
	@failed=; for h in $(3); do \
		if $(1) --rm --entrypoint getent $(2) ahosts $$h >/dev/null 2>&1; then \
			echo "  ok   $$h"; else echo "  FAIL $$h"; failed="$$failed $$h"; fi; \
	done; \
	if [ -n "$$failed" ]; then \
		echo "DNS lookups failed from inside the container:$$failed"; \
		echo "Check the host's network/firewall (e.g. Docker setting FORWARD to DROP) and retry."; \
		exit 1; \
	fi
endef

check-dns:
	@echo "Checking DNS from a rootless build container"
	$(call dns_check,podman run --pull=missing,quay.io/fedora-ostree-desktops/kinoite:$(FEDORA_VERSION),$(BUILD_HOSTS))

check-dns-root:
	@echo "Checking DNS from a root container with --net=host (as bootc-image-builder runs)"
	$(call dns_check,sudo podman run --pull=$(BIB_PULL) --net=host,$(BIB_IMAGE),$(ISO_HOSTS))

BUILD = podman build --pull=$(PULL) \
	--build-arg FEDORA_VERSION=$(FEDORA_VERSION) --build-arg IMAGE_REF=$(IMAGE_REF) \
	-t $(LOCAL_IMAGE)

build: check-dns
	$(BUILD) .

build-fresh: check-dns
	$(BUILD) --no-cache .

lint:
	podman run --rm -v ./:/mnt:ro,Z -w /mnt docker.io/koalaman/shellcheck:stable \
		build_files/*.sh system_files/usr/libexec/bioinformatico-flatpaks \
		system_files/usr/bin/bioinformatico-user-setup

# bootc-image-builder runs as root and reads the image from root's container storage.
# /store (osbuild's cache, including downloaded RPMs) and /rpmmd (DNF metadata) persist in
# $(CACHE)/, so a retry picks up where the last run stopped.
# --net=host: rootful bridge networking breaks when the host's firewall drops forwarded
# traffic (e.g. Docker sets FORWARD to DROP), which shows up as DNS failures while depsolving.
# Ubuntu's AppArmor profile bwrap-userns-restrict strips every capability from whatever
# /usr/bin/bwrap launches, and it attaches by path, so it hits osbuild's sandbox inside the
# privileged container too ("mount: /run/osbuild/tree/dev: permission denied"). If it's loaded,
# unload it for the duration of the build and reload it afterwards, even on failure or Ctrl-C.
BWRAP_PROFILE = /etc/apparmor.d/bwrap-userns-restrict
# bootc-image-builder picks its own file name, so rename it to something predictable
ISO_FILE = $(OUTPUT)/bootiso/bioinformatico-ostree-$(FEDORA_VERSION).iso

define bib
	mkdir -p $(OUTPUT) $(CACHE)/store $(CACHE)/rpmmd
	@restore=; \
	reload() { \
		if [ -n "$$restore" ]; then \
			echo "Reloading AppArmor profile $(BWRAP_PROFILE)"; \
			sudo apparmor_parser -r $(BWRAP_PROFILE); restore=; \
		fi; \
	}; \
	trap reload EXIT; trap 'reload; exit 130' INT TERM; \
	if [ -f $(BWRAP_PROFILE) ] && sudo grep -q '^bwrap ' /sys/kernel/security/apparmor/profiles 2>/dev/null; then \
		echo "Temporarily unloading AppArmor profile $(BWRAP_PROFILE) (it blocks osbuild's sandbox)"; \
		sudo apparmor_parser -R $(BWRAP_PROFILE) && restore=1; \
	fi; \
	sudo podman run --rm -it --privileged --pull=$(BIB_PULL) --net=host \
		--security-opt label=type:unconfined_t \
		-v ./$(OUTPUT):/output \
		-v ./$(CACHE)/store:/store \
		-v ./$(CACHE)/rpmmd:/rpmmd \
		-v ./disk_config/iso.toml:/config.toml:ro \
		-v /var/lib/containers/storage:/var/lib/containers/storage \
		$(BIB_IMAGE) --type anaconda-iso --rootfs btrfs --use-librepo=True \
		--chown $$(id -u):$$(id -g) $(1)
	@iso=$$(ls -t $(OUTPUT)/bootiso/*.iso | head -1); \
	[ "$$iso" = "$(ISO_FILE)" ] || mv -f "$$iso" $(ISO_FILE); \
	echo "ISO: $(ISO_FILE)"
endef

# Copying ~8 GB into root's storage is slow, so only do it when the image has changed.
# check-dns-root comes first so a network problem fails before the build and image copy.
iso: check-dns-root build
	@id=$$(podman image inspect -f '{{.Id}}' $(LOCAL_IMAGE)); \
	if [ "$$(sudo podman image inspect -f '{{.Id}}' $(LOCAL_IMAGE) 2>/dev/null)" = "$$id" ]; then \
		echo "Root storage already has this image"; \
	else \
		echo "Copying image to root storage"; \
		podman save $(LOCAL_IMAGE) | sudo podman load; \
	fi
	$(call bib,$(LOCAL_IMAGE))

iso-remote: check-dns-root
	sudo podman pull --retry 5 $(IMAGE_REF):latest
	$(call bib,$(IMAGE_REF):latest)

cosign-keys:
	@test ! -e cosign.key || { echo "cosign.key already exists"; exit 1; }
	podman run --rm -it -v ./:/keys:Z -w /keys ghcr.io/sigstore/cosign/cosign:latest \
		generate-key-pair
	@echo "Commit cosign.pub. Put the contents of cosign.key in the repo secret SIGNING_SECRET"
	@echo "(and the password, if any, in COSIGN_PASSWORD). Never commit cosign.key."

clean:
	sudo rm -rf $(OUTPUT)

clean-cache:
	sudo rm -rf $(CACHE)
	buildah prune -f
