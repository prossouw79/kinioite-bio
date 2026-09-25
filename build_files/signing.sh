#!/usr/bin/bash
# Make the installed system refuse unsigned updates of this image.
set -xeuo pipefail

IMAGE_REF="${IMAGE_REF:?}"
registry=${IMAGE_REF%%/*}

install -Dm0644 /ctx/cosign.pub /etc/pki/containers/prossouw79.pub

tmp=$(mktemp)
jq --arg ref "$IMAGE_REF" '.transports.docker[$ref] = [{
      type: "sigstoreSigned",
      keyPath: "/etc/pki/containers/prossouw79.pub",
      signedIdentity: {type: "matchRepository"}
    }]' /etc/containers/policy.json > "$tmp"
install -m0644 "$tmp" /etc/containers/policy.json
rm -f "$tmp"

cat > "/etc/containers/registries.d/${registry}-prossouw79.yaml" <<YAML
docker:
  ${IMAGE_REF}:
    use-sigstore-attachments: true
YAML
