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
  local download_url="${6:-}"
  local cmp update_available="false"
  ss_ensure_dirs
  if [ -n "$latest" ]; then
    cmp=$(ss_version_cmp "$latest" "$installed")
    [ "$cmp" = "1" ] && update_available="true"
  fi
  # Keep previous download_url if new one empty
  if [ -z "$download_url" ] && [ -f "$SS_VERSION_FILE" ]; then
    download_url=$(jq -r '.download_url // empty' "$SS_VERSION_FILE" 2>/dev/null)
  fi
  [ -n "$download_url" ] || download_url="$ADDON_RELEASE_TGZ"
  jq -nc \
    --arg installed "$installed" \
    --arg latest "${latest:-}" \
    --arg tag "${tag:-}" \
    --arg url "${url:-}" \
    --arg download_url "$download_url" \
    --arg repo "${ADDON_REPO}" \
    --arg err "${err:-}" \
    --argjson update_available "$update_available" \
    --argjson checked_at "$(date +%s)" \
    '{
      installed: $installed,
      latest: (if $latest == "" then null else $latest end),
      tag: (if $tag == "" then null else $tag end),
      release_url: (if $url == "" then null else $url end),
      download_url: $download_url,
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
  local prev_latest prev_tag prev_url prev_dl
  if [ -f "$SS_VERSION_FILE" ]; then
    prev_latest=$(jq -r '.latest // empty' "$SS_VERSION_FILE" 2>/dev/null)
    prev_tag=$(jq -r '.tag // empty' "$SS_VERSION_FILE" 2>/dev/null)
    prev_url=$(jq -r '.release_url // empty' "$SS_VERSION_FILE" 2>/dev/null)
    prev_dl=$(jq -r '.download_url // empty' "$SS_VERSION_FILE" 2>/dev/null)
    ss_version_write "$ADDON_VERSION" "$prev_latest" "$prev_tag" "$prev_url" "" "$prev_dl"
  else
    ss_version_write "$ADDON_VERSION" "" "" "" "" "$ADDON_RELEASE_TGZ"
  fi
}

ss_version_check() {
  # Query GitHub latest release; update version.json
  local resp tag latest url http_code tmp err="" asset=""
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
        "$err" \
        "$(jq -r '.download_url // empty' "$SS_VERSION_FILE")" >/dev/null
    else
      ss_version_write "$ADDON_VERSION" "" "" "" "$err" "$ADDON_RELEASE_TGZ" >/dev/null
    fi
    rm -f "$tmp"
    cat "$SS_VERSION_FILE"
    return 1
  fi

  tag=$(jq -r '.tag_name // empty' "$tmp")
  latest=$(ss_version_normalize "$tag")
  url=$(jq -r '.html_url // empty' "$tmp")
  asset=$(jq -r '
    (.assets // [])[]
    | select(.name == "asuswrt-merlin-stealthsurf.tar.gz")
    | .browser_download_url
  ' "$tmp" 2>/dev/null | head -1)
  if [ -z "$asset" ]; then
    # Releases without uploaded asset: use /latest/download redirect URL
    asset="$ADDON_RELEASE_TGZ"
  fi

  rm -f "$tmp"
  ss_version_write "$ADDON_VERSION" "$latest" "$tag" "$url" "" "$asset" >/dev/null
  if jq -e '.update_available == true' "$SS_VERSION_FILE" >/dev/null 2>&1; then
    ss_ok "Update available: $ADDON_VERSION → $latest ($tag)"
    ss_activity "version.update_available" "installed=$ADDON_VERSION latest=$latest"
  else
    ss_ok "Up to date ($ADDON_VERSION), latest on GitHub: ${latest:-unknown}"
    ss_activity "version.uptodate" "installed=$ADDON_VERSION latest=$latest"
  fi
  cat "$SS_VERSION_FILE"
}

ss_version_download_url() {
  local url=""
  if [ -f "$SS_VERSION_FILE" ]; then
    url=$(jq -r '.download_url // empty' "$SS_VERSION_FILE" 2>/dev/null)
  fi
  [ -n "$url" ] || url="$ADDON_RELEASE_TGZ"
  printf '%s' "$url"
}

ss_version_update_if_available() {
  # Install from GitHub only if newer (or force=1).
  # Exit 2 = already up to date (no download); 0 = installed; 1 = failure.
  local force="${1:-0}"
  local info
  info=$(ss_version_check) || true
  if [ "$force" != "1" ] && ! printf '%s' "$info" | jq -e '.update_available == true' >/dev/null 2>&1; then
    ss_info "No newer release to install (installed=$ADDON_VERSION)"
    printf '%s\n' "$info"
    return 2
  fi
  ss_update_self
}
