#!/usr/bin/env bash
#
# One-click installer for 5gpn — downloads the repo and runs install.sh.
#
#   curl -fsSL https://raw.githubusercontent.com/lingchenfs1/5gpn/main/quick-install.sh -o /tmp/5gpn.sh && sudo bash /tmp/5gpn.sh
#
# (Avoid `sudo bash <(curl ...)`: newer sudo closes the process-substitution
#  fd, which fails as "/dev/fd/63: No such file or directory" on e.g. Debian 13.)
#
# Any extra args are passed straight through to install.sh, e.g.:
#   sudo bash /tmp/5gpn.sh --status
#
set -euo pipefail

REPO="Xiuyixx/5GPN-X"
BRANCH="${PGW_BRANCH:-main}"
DIR="${PGW_SRC_DIR:-/opt/5gpn}"

RED='\033[0;31m'; BLUE='\033[0;34m'; GREEN='\033[0;32m'; NC='\033[0m'
info() { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
err()  { echo -e "${RED}[ERR]${NC}  $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "Run as root:  curl -fsSL https://raw.githubusercontent.com/${REPO}/${BRANCH}/quick-install.sh -o /tmp/5gpn.sh && sudo bash /tmp/5gpn.sh"
    exit 1
fi

pkg_install() {
    if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update -qq && apt-get install -y -qq "$@"
    elif command -v dnf >/dev/null 2>&1; then dnf install -y -q "$@"
    elif command -v yum >/dev/null 2>&1; then yum install -y -q "$@"
    else return 1; fi
}

command -v git >/dev/null 2>&1 || pkg_install git || { err "git is required"; exit 1; }

info "Downloading ${REPO}@${BRANCH} into ${DIR} ..."
if [[ -d "${DIR}/.git" ]]; then
    info "Existing repo found, pulling latest..."
    git -C "${DIR}" fetch origin "${BRANCH}" --quiet
    git -C "${DIR}" reset --hard "origin/${BRANCH}"
else
    rm -rf "${DIR}"
    if ! git clone --depth 1 -b "${BRANCH}" "https://github.com/${REPO}.git" "${DIR}"; then
        err "git clone failed. Check network access to github.com."
        exit 1
    fi
fi
ok "Source ready at ${DIR}"

cd "${DIR}"
chmod +x install.sh quick-install.sh lib/update-rules.sh 2>/dev/null || true
info "Launching installer..."
exec bash ./install.sh "$@"
