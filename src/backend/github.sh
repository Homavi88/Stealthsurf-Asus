#!/bin/sh
# shellcheck disable=SC2034  # codacy:Unused variables

# User-configured proxy first; empty = direct GitHub URL.
github_proxy_url() {
    load_xrayui_config
    local url="$1"
    local ghproxy="${github_proxy:-""}"

    if [ -z "$url" ] || [ "$url" = "null" ]; then
        echo "$url"
        return
    fi

    case "$url" in
    *github.com*)
        if [ -n "$ghproxy" ] && [ "$ghproxy" != "null" ]; then
            url="${ghproxy}${url}"
        fi
        ;;
    esac

    echo "$url"
}

# Built-in GitHub release mirrors (blocked regions). Prefixed to https://github.com/...
# Prefer mirrors that also proxy api.github.com (update checks).
github_default_mirrors() {
    printf '%s\n' \
        'https://gh-proxy.com/' \
        'https://cdn.gh-proxy.org/' \
        'https://ghfast.top/' \
        'https://gitproxy.click/' \
        'https://github.moeyy.xyz/'
}

github_https_bin() {
    if [ -x /opt/bin/curl ]; then
        echo /opt/bin/curl
        return 0
    fi
    if command -v curl >/dev/null 2>&1; then
        command -v curl
        return 0
    fi
    if [ -x /opt/bin/wget ]; then
        echo /opt/bin/wget
        return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        command -v wget
        return 0
    fi
    return 1
}

# Emit candidate URLs (one per line): user-proxied, direct, then default mirrors.
github_url_candidates() {
    local url="$1"
    local proxied
    proxied=$(github_proxy_url "$url")

    [ -n "$proxied" ] && [ "$proxied" != "null" ] && printf '%s\n' "$proxied"
    [ "$proxied" != "$url" ] && printf '%s\n' "$url"

    case "$url" in
    *github.com* | *githubusercontent.com*)
        github_default_mirrors | while IFS= read -r mirror; do
            [ -n "$mirror" ] || continue
            printf '%s%s\n' "$mirror" "$url"
        done
        ;;
    esac
}

# Download $1 → $2 with retries + mirrors. Optional $3 = min bytes (default 1), $4 = label.
github_download() {
    local url="$1"
    local out="$2"
    local min_bytes="${3:-1}"
    local label="${4:-$(basename "$out")}"
    local bin attempt candidate tmp sz cand_file

    if [ -z "$url" ] || [ -z "$out" ]; then
        log_error "github_download: url/out required"
        return 1
    fi

    bin=$(github_https_bin) || {
        log_error "No HTTPS client (install Entware curl)."
        return 1
    }

    mkdir -p "$(dirname "$out")" 2>/dev/null || true
    tmp="${out}.part.$$"
    cand_file="${ADDON_TMP_DIR:-/tmp}/ssurf_urlcand.$$"
    mkdir -p "$(dirname "$cand_file")" 2>/dev/null || true
    github_url_candidates "$url" | awk 'NF && !seen[$0]++' >"$cand_file"

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        attempt=1
        while [ "$attempt" -le 2 ]; do
            if [ "${USE_COLOR:-0}" -eq 1 ] && type install_ui_fetch >/dev/null 2>&1; then
                install_ui_fetch "$label" "$candidate" "$attempt"
            else
                log_info "Fetching $label (try $attempt)"
                log_debug "URL: $candidate"
            fi

            rm -f "$tmp"
            case "$bin" in
            *curl)
                if [ "${USE_COLOR:-0}" -eq 1 ] && [ -t 2 ]; then
                    "$bin" -fL --connect-timeout 25 --retry 2 --retry-delay 2 \
                        --progress-bar -o "$tmp" "$candidate" 2>&1 || true
                else
                    "$bin" -fsSL --connect-timeout 25 --retry 2 --retry-delay 2 \
                        -o "$tmp" "$candidate" || true
                fi
                ;;
            *wget)
                "$bin" -q --timeout=30 --tries=2 --no-hsts -O "$tmp" "$candidate" || true
                ;;
            *)
                rm -f "$cand_file"
                return 1
                ;;
            esac

            if [ -s "$tmp" ]; then
                sz=$(wc -c <"$tmp" 2>/dev/null | tr -d ' ')
                if [ -n "$sz" ] && [ "$sz" -ge "$min_bytes" ] 2>/dev/null; then
                    mv -f "$tmp" "$out"
                    rm -f "$cand_file"
                    if type install_ui_status >/dev/null 2>&1; then
                        install_ui_status ok "$label ($(install_ui_humansize "$sz"))"
                    else
                        log_ok "Downloaded $label ($sz bytes)"
                    fi
                    return 0
                fi
                log_warn "$label too small ($sz < $min_bytes), retrying…"
            fi
            rm -f "$tmp"
            attempt=$((attempt + 1))
            [ "$attempt" -le 2 ] && sleep 1
        done
    done <"$cand_file"

    rm -f "$tmp" "$out" "$cand_file"
    log_error "Failed to download $label from all mirrors"
    type install_ui_status >/dev/null 2>&1 && install_ui_status fail "$label"
    return 1
}
