#!/usr/bin/env bash
# shellcheck disable=SC2034,SC1091 # Globals and dynamic source are consumed by install_deps.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

mkdir -p "${tmp}/bin"
cat > "${tmp}/bin/apt-get" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOCK_CALLS}"
echo 'Setting up jq (1.7.1-6+deb13u3) ...'
echo 'Setting up libc6-dev:amd64 (2.41-12+deb13u3) ...' >&2
EOF
cat > "${tmp}/bin/go" <<'EOF'
#!/usr/bin/env bash
echo 'go version go1.22.4 linux/amd64'
EOF
cat > "${tmp}/bin/certbot" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "${tmp}/bin/apt-get" "${tmp}/bin/go" "${tmp}/bin/certbot"

export MOCK_CALLS="${tmp}/calls"
PATH="${tmp}/bin:${PATH}"
OS=debian
VER=13
PKG_MGR=apt-get

info() { printf 'INFO %s\n' "$*"; }
ok()   { printf 'OK %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
err()  { printf 'ERR %s\n' "$*" >&2; }

# shellcheck source=../lib/services.sh
. "${root}/lib/services.sh"

output="$(install_deps 2>&1)"

[[ "$output" != *'Setting up jq'* ]] || {
    echo "normal apt/dpkg package setup output must stay out of the terminal" >&2
    exit 1
}
[[ "$output" != *'Setting up libc6-dev'* ]] || {
    echo "stderr package setup output must stay out of the terminal" >&2
    exit 1
}
[[ "$output" == *'System packages installed'* ]] || {
    echo "installer must print one concise package completion message" >&2
    exit 1
}
grep -q '^-o DPkg::Lock::Timeout=300 update -qq$' "$MOCK_CALLS" || {
    echo "installer must wait for the dpkg lock while updating apt metadata" >&2
    exit 1
}
grep -q '^-o DPkg::Lock::Timeout=300 install -y -qq .*libpcre2-dev' "$MOCK_CALLS" || {
    echo "installer must wait for the dpkg lock while installing Debian 13 dependencies" >&2
    exit 1
}

APT_LOCK_TIMEOUT=17
export APT_LOCK_TIMEOUT
: > "$MOCK_CALLS"
install_deps >/dev/null 2>&1
grep -q '^-o DPkg::Lock::Timeout=17 install -y -qq ' "$MOCK_CALLS" || {
    echo "installer must honor the configured apt lock timeout" >&2
    exit 1
}
unset APT_LOCK_TIMEOUT

INSTALL_LOG="${tmp}/persistent-install.log"
if ! persistent_output="$(install_deps 2>&1)"; then
    echo "dependency installation must succeed when using the persistent install log" >&2
    printf '%s\n' "$persistent_output" >&2
    exit 1
fi
[[ "$persistent_output" != *'Setting up jq'* ]] || {
    echo "persistent logging must not leak apt output to the terminal" >&2
    exit 1
}
grep -q 'Setting up jq' "$INSTALL_LOG" || {
    echo "persistent install log must retain apt output" >&2
    exit 1
}

echo "quiet dependency installation OK"
