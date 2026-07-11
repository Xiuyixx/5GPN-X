#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
template="$(cat "${root}/lib/dnsdist.conf.template")"
race_proxy="$(cat "${root}/lib/china-dns-race-proxy.go")"

for dns in '101.226.4.6:53' '218.30.118.6:53' '180.76.76.76:53' '119.29.29.29:53'; do
    if [[ "${race_proxy}" != *"${dns}"* ]]; then
        echo "China DNS race proxy must keep ${dns} in the primary domestic resolver set." >&2
        exit 1
    fi
    if [[ "${template}" == *"${dns}"* ]]; then
        echo "dnsdist must not query ${dns} directly; it should use the local race proxy." >&2
        exit 1
    fi
done

if [[ "${race_proxy}" != *'1.1.1.1:53,8.8.8.8:53,22.22.22.22:53'* ]]; then
    echo "China DNS race proxy must include overseas fallback resolvers so ChinaList lookups do not stall when domestic DNS is unreachable." >&2
    exit 1
fi

if [[ "${race_proxy}" == *'223.5.5.5'* ]]; then
    echo "China DNS race proxy must not include AliDNS because it times out on some JD CDN domains with ECS." >&2
    exit 1
fi

if [[ "${template}" != *'address="127.0.0.1:5301", pool="china", name="china_dns_race"'* ]]; then
    echo "China DNS pool should route through the local race proxy." >&2
    exit 1
fi

if [[ "${race_proxy}" != *'raceTCPDelay      = flag.Duration("tcp-delay", 150*time.Millisecond'* ]]; then
    echo "China DNS race proxy must retry domestic resolvers over TCP shortly after UDP stalls." >&2
    exit 1
fi

if [[ "${race_proxy}" != *'raceFallbackDelay = flag.Duration("fallback-delay", 750*time.Millisecond'* ]]; then
    echo "China DNS race proxy must give domestic TCP a chance before overseas fallback resolvers." >&2
    exit 1
fi

echo "China DNS race upstream policy OK"
