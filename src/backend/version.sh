#!/bin/sh
# Installed version + GitHub Releases check / update highlight

ss_version_normalize() {
  printf '%s' "$1" | sed 's/^[vV]//; s/[^0-9.].*$//'
}

ss_version_cmp() {
  # ss_version_cmp A B → echo -1|0|1 (A<B / equal / A>B) using sort -V
  local a b top
  a=$(ss_version_normalize "$1")
  b=$(ss_version_normalize "$2")
  [ -n "$a" ] || a="0"
  [ -n "$b" ] || b="0"
  if [ "$a" = "$b" ]; then
    echo 0
    return 0
  fi
  top=$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1)
  if [ "$top" = "$a" ]; then
    echo 1
  else
    echo -1
  fi
}

ss_version_write() {
  local installed="${1:-$ADDON_VERSION}"
  local latest="${2:-}"
  local tag="${3:-}"
  local url="${4:-}"
  local err="${5:-}"
  local cmp update_available="false"
  ss_ensure_dirs
  if [ -n "$latest" ]; then
    cmp=$(ss_version_cmp "$latest" "$installed")
    [ "$cmp" = "1" ] && update_available="true"
  fi
  jq -nc \
    --arg installed "$installed" \
    --arg latest "${latest:-}" \
    --arg tag "${tag:-}" \
    --arg url "${url:-}" \
    --arg repo "${ADDON_REPO}" \
    --arg err "${err:-}" \
    --argjson update_available "$update_available" \
    --argjson checked_at "$(date +%s)" \
    '{
      installed: $installed,
      latest: (if $latest == "" then null else $latest end),
      tag: (if $tag == "" then null else $tag end),
      release_url: (if $url == "" then null else $url end),
      repo: $repo,
      update_available: $update_available,
      checked_at: $checked_at,
      error: (if $err == "" then null else $err end)
    }' >"$SS_VERSION_FILE"
  ln -sf "$SS_VERSION_FILE" "$ADDON_WEB_DIR/version.json" 2>/dev/null || true
  cat "$SS_VERSION_FILE"
}

ss_version_local() {
  # Always refresh installed field even offline
  local prev_latest prev_tag prev_url
  if [ -f "$SS_VERSION_FILE" ]; then
    prev_latest=$(jq -r '.latest // empty' "$SS_VERSION_FILE" 2>/dev/null)
    prev_tag=$(jq -r '.tag // empty' "$SS_VERSION_FILE" 2>/dev/null)
    prev_url=$(jq -r '.release_url // empty' "$SS_VERSION_FILE" 2>/dev/null)
    ss_version_write "$ADDON_VERSION" "$prev_latest" "$prev_tag" "$prev_url"
  else
    ss_version_write "$ADDON_VERSION" "" "" ""
  fi
}

ss_version_check() {
  # Query GitHub latest release; update version.json
  local resp tag latest url http_code tmp err=""
  ss_ensure_dirs
  ss_activity "version.check" "repo=$ADDON_REPO installed=$ADDON_VERSION"
  tmp="$ADDON_TMP_DIR/gh-release.$$"
  http_code=$(curl -sS -o "$tmp" -w '%{http_code}' \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: stealthsurf-merlin/$ADDON_VERSION" \
    --connect-timeout 12 --max-time 25 \
    "$ADDON_RELEASE_API" 2>/dev/null) || http_code="000"

  if [ "$http_code" != "200" ] || ! jq -e . "$tmp" >/dev/null 2>&1; then
    err="GitHub HTTP ${http_code:-000}"
    ss_warn "Version check failed: $err"
    ss_activity "version.check.fail" "$err"
    # Keep previous latest if any
    if [ -f "$SS_VERSION_FILE" ]; then
      ss_version_write "$ADDON_VERSION" \
        "$(jq -r '.latest // empty' "$SS_VERSION_FILE")" \
        "$(jq -r '.tag // empty' "$SS_VERSION_FILE")" \
        "$(jq -r '.release_url // empty' "$SS_VERSION_FILE")" \
        "$err" >/dev/null
    else
      ss_version_write "$ADDON_VERSION" "" "" "" "$err" >/dev/null
    fi
    rm -f "$tmp"
    cat "$SS_VERSION_FILE"
    return 1
  fi

  tag=$(jq -r '.tag_name // empty' "$tmp")
  latest=$(ss_version_normalize "$tag")
  url=$(jq -r '.html_url // empty' "$tmp")
  # Prefer asset download URL if present
  asset=$(jq -r '
    (.assets // [])[]
    | select(.name == "asuswrt-merlin-stealthsurf.tar.gz")
    | .browser_download_url
  ' "$tmp" 2>/dev/null | head -1)
  [ -n "$asset" ] && ADDON_RELEASE_TGZ="$asset"

  rm -f "$tmp"
  ss_version_write "$ADDON_VERSION" "$latest" "$tag" "$url" >/dev/null
  if jq -e '.update_available == true' "$SS_VERSION_FILE" >/dev/null 2>&1; then
    ss_ok "Update available: $ADDON_VERSION → $latest ($tag)"
    ss_activity "version.update_available" "installed=$ADDON_VERSION latest=$latest"
  else
    ss_ok "Up to date ($ADDON_VERSION), latest on GitHub: ${latest:-unknown}"
    ss_activity "version.uptodate" "installed=$ADDON_VERSION latest=$latest"
  fi
  cat "$SS_VERSION_FILE"
}

ss_version_update_if_available() {
  # Install from GitHub only if newer (or force=1)
  local force="${1:-0}"
  local info
  info=$(ss_version_check) || true
  if [ "$force" != "1" ] && ! printf '%s' "$info" | jq -e '.update_available == true' >/dev/null 2>&1; then
    ss_info "No newer release to install"
    return 0
  fi
  ss_update_self
}
