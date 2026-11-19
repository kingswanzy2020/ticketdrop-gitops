#!/usr/bin/env bash
# Installs the named tools into $RUNNER_TEMP/bin (or ./bin), each at a fixed
# version and checked against a fixed SHA-256 before it is used:
#
#   .github/scripts/install-tools.sh helm kubeconform shellcheck
#
# The runner image has its own helm, kubectl and kind, but at whatever version
# the image carries that week. These are the versions the laptop uses, so a
# check passes or fails the same way in both places.
#
# The kind, kubeconform, helm and kubectl hashes are the ones each project
# publishes. shellcheck publishes none; its hash was taken from the release
# file on 19 November 2026.
set -euo pipefail

bin=${RUNNER_TEMP:-.}/bin
mkdir -p "$bin"

fetch() { # url sha256 file
  curl -fsSL --retry 3 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c --quiet -
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cd "$tmp"

for tool in "$@"; do
  case $tool in
    helm)
      fetch https://get.helm.sh/helm-v3.20.2-linux-amd64.tar.gz \
        258e830a9e613c8a7a302d6059b4bb3b9758f2f3e1bb8ea0d707ce10a9a72fea helm.tgz
      tar xzf helm.tgz linux-amd64/helm
      install linux-amd64/helm "$bin/helm"
      ;;
    kubeconform)
      fetch https://github.com/yannh/kubeconform/releases/download/v0.8.0/kubeconform-linux-amd64.tar.gz \
        9bc2bffbf71f261128533edaf912153948b7ff238f9a531ae6d34466ec287883 kubeconform.tgz
      tar xzf kubeconform.tgz kubeconform
      install kubeconform "$bin/kubeconform"
      ;;
    shellcheck)
      fetch https://github.com/koalaman/shellcheck/releases/download/v0.11.0/shellcheck-v0.11.0.linux.x86_64.tar.xz \
        8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198 shellcheck.txz
      tar xJf shellcheck.txz shellcheck-v0.11.0/shellcheck
      install shellcheck-v0.11.0/shellcheck "$bin/shellcheck"
      ;;
    kind)
      fetch https://github.com/kubernetes-sigs/kind/releases/download/v0.33.0/kind-linux-amd64 \
        aee6151561422756b764a4ae28e7f44cda5af5a9eead3cc9985112b1de8d8e0d kind
      install kind "$bin/kind"
      ;;
    kubectl)
      fetch https://dl.k8s.io/release/v1.36.4/bin/linux/amd64/kubectl \
        8b8f088da2dab964f853b38464033b1be15ede2839eca751482357c45abdd05a kubectl
      install kubectl "$bin/kubectl"
      ;;
    *)
      echo "unknown tool: $tool" >&2
      exit 2
      ;;
  esac
  echo "installed $tool"
done

if [[ -n ${GITHUB_PATH:-} ]]; then
  echo "$bin" >> "$GITHUB_PATH"
fi
