#!/usr/bin/bash
# Final, cheap build step: settings that depend on the installed packages and this repo's files.
set -xeuo pipefail

ONEPASSWORD_USERS="${ONEPASSWORD_USERS:?}"

### 1Password's polkit policy lists which users may approve CLI/SSH-agent requests. Its
# scriptlet fills that from /etc/passwd, which is empty of humans at build time.
read -ra users <<< "$ONEPASSWORD_USERS"
owners=$(printf 'unix-user:%s ' "${users[@]}")
sed "s|\${POLICY_OWNERS}|${owners% }|" /usr/lib/opt/1Password/com.1password.1Password.policy.tpl \
  > /usr/share/polkit-1/actions/com.1password.1Password.policy

# Sanity-check the permissions 1Password's integrations depend on
[[ $(stat -c '%g %A' /usr/bin/op) == "881 "*s* ]]
[[ $(stat -c '%g %A' /usr/lib/opt/1Password/1Password-BrowserSupport) == "880 "*s* ]]

### Services
systemctl enable prossouw79-flatpaks.service
systemctl enable virtqemud.socket virtnetworkd.socket virtstoraged.socket \
  virtnodedevd.socket virtsecretd.socket virtinterfaced.socket virtnwfilterd.socket
systemctl --global enable podman.socket

### Image signature verification (only once a cosign key has been added to the repo)
if [[ -f /ctx/cosign.pub ]]; then
  /ctx/build_files/signing.sh
fi

### Third-party repos are only needed while building. Installed systems update by pulling
# a new image, and bootc-image-builder resolves the ISO's installer packages against every
# enabled repo, so leaving them on only adds network dependencies to `make iso`.
sed -i 's/^enabled=1/enabled=0/' \
  /etc/yum.repos.d/{1password,google-chrome,microsoft-edge,vscode}.repo

### /var from the image only reaches a machine on a fresh install (not on `bootc switch`),
# so have systemd create the state directories these packages expect at boot.
find /var/lib/libvirt /var/lib/iscsi /var/lib/swtpm-localca -type d \
  -printf 'd %p %m %u %g - -\n' > /usr/lib/tmpfiles.d/prossouw79-var.conf
