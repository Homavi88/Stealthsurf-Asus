#!/bin/sh
# Installed version + GitHub Releases check / update highlight + human changelog

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

ss_version_clean_bullet() {
  # Strip markdown/PR noise → plain line for UI
  printf '%s' "$1" |
    sed -E \
      -e 's/^[*#-]+[[:space:]]*//' \
      -e 's/\*\*([^*]+)\*\*/\1/g' \
      -e 's/`([^`]+)`/\1/g' \
      -e 's/[[:space:]]+by @[A-Za-z0-9_-]+([[:space:]]+in[[:space:]]+(#[0-9]+|https?:\/\/[^[:space:]]+))?[[:space:]]*$//' \
      -e 's/[[:space:]]+\(#[0-9]+\)[[:space:]]*$//' \
      -e 's/[[:space:]]+in https?:\/\/[^[:space:]]+//' \
      -e 's/^docs:[[:space:]]*/Документация: /I' \
      -e 's/^fix:[[:space:]]*/Исправление: /I' \
      -e 's/^feat(\([^)]*\))?:[[:space:]]*/Новое: /I' \
      -e 's/^chore(\([^)]*\))?:[[:space:]]*//' \
      -e 's/^ci(\([^)]*\))?:[[:space:]]*/CI: /I' \
      -e 's/^Release v[0-9.]+[[:space:]]*:[[:space:]]*//' \
      -e 's/^[[:space:]]+//;s/[[:space:]]+$//'
}

ss_version_classify_line() {
  # echo features|fixes|other|skip — grep so BusyBox case need not handle unicode/spaces
  local line="$1"
  [ -n "$line" ] || {
    echo skip
    return 0
  }
  printf '%s' "$line" | grep -qiE 'what.?s changed|full changelog|new contributors|^---+$' && {
    echo skip
    return 0
  }
  printf '%s' "$line" | grep -qiE 'release v[0-9]|merge pull request|bump version|ship main' && {
    echo skip
    return 0
  }
  if printf '%s' "$line" | grep -qiE 'fix|bug|crash|ошибк|исправ|blackhole|конфликт|conflict|broken|не работ'; then
    echo fixes
    return 0
  fi
  if printf '%s' "$line" | grep -qiE 'feat|added|\badd\b|новое|добав|modal|screenshot|\bcli\b|баннер|guard|\bblock\b|блок|xrayui|оптимиз|optim|performance|\bcpu\b|memory|\bram\b|\bui\b|webui|changelog|human'; then
    echo features
    return 0
  fi
  if printf '%s' "$line" | grep -qiE 'docs|readme|документац|chore|\bci\b|workflow'; then
    echo other
    return 0
  fi
  echo other
}

ss_version_humanize_notes() {
  # Args: raw_body [tag] [name]
  # Prints JSON changelog object for version.json / UI modal
  local raw="${1:-}"
  local tag="${2:-}"
  local name="${3:-}"
  local tmp features_file fixes_file other_file line cleaned kind
  tmp=$(mktemp -d 2>/dev/null || echo "/tmp/ss-notes.$$")
  mkdir -p "$tmp" 2>/dev/null || true
  features_file="$tmp/features.txt"
  fixes_file="$tmp/fixes.txt"
  other_file="$tmp/other.txt"
  : >"$features_file"
  : >"$fixes_file"
  : >"$other_file"

  # Prefer bullet lines (no pipe→while: BusyBox runs that in a subshell)
  printf '%s\n' "$raw" >"$tmp/body.txt"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
    \#\#\#* | \#\#* | \#*) continue ;;
    esac
    case "$line" in
    [\*\-][[:space:]]* | [0-9].*)
      cleaned=$(ss_version_clean_bullet "$line")
      [ -n "$cleaned" ] || continue
      [ "${#cleaned}" -lt 8 ] && continue
      kind=$(ss_version_classify_line "$cleaned")
      case "$kind" in
      features) printf '%s\n' "$cleaned" >>"$features_file" ;;
      fixes) printf '%s\n' "$cleaned" >>"$fixes_file" ;;
      other) printf '%s\n' "$cleaned" >>"$other_file" ;;
      esac
      ;;
    esac
  done <"$tmp/body.txt"

  # Deduplicate + cap lists
  local features_json fixes_json other_json headline summary feat_n fix_n oth_n
  features_json=$(awk 'NF && !seen[$0]++' "$features_file" 2>/dev/null | head -12 | jq -Rsc 'split("\n")|map(select(length>0))')
  fixes_json=$(awk 'NF && !seen[$0]++' "$fixes_file" 2>/dev/null | head -12 | jq -Rsc 'split("\n")|map(select(length>0))')
  other_json=$(awk 'NF && !seen[$0]++' "$other_file" 2>/dev/null | head -8 | jq -Rsc 'split("\n")|map(select(length>0))')
  [ -n "$features_json" ] || features_json='[]'
  [ -n "$fixes_json" ] || fixes_json='[]'
  [ -n "$other_json" ] || other_json='[]'
  feat_n=$(printf '%s' "$features_json" | jq 'length')
  fix_n=$(printf '%s' "$fixes_json" | jq 'length')
  oth_n=$(printf '%s' "$other_json" | jq 'length')

  if [ "$feat_n" -gt 0 ] && [ "$fix_n" -gt 0 ]; then
    headline="Новые возможности и исправления ошибок"
  elif [ "$feat_n" -gt 0 ]; then
    headline="Новые возможности"
  elif [ "$fix_n" -gt 0 ]; then
    headline="Исправления ошибок"
  else
    headline="Обновление аддона"
  fi

  if [ -n "$name" ] && [ "$name" != "null" ]; then
    summary="Версия ${tag:-новая}: $name. $headline — кратко ниже, подробно на GitHub."
  else
    summary="Доступна версия ${tag:-на GitHub}. $headline. Ниже — коротко по-человечески; полный список — в релизе на GitHub."
  fi

  # Fallback if GitHub body empty / nothing classified
  if [ "$((feat_n + fix_n + oth_n))" -eq 0 ]; then
    other_json=$(jq -nc --arg t "${tag:-latest}" '["Откройте страницу релиза на GitHub, чтобы увидеть полный список изменений " + $t + "."]')
    summary="Доступна новая версия ${tag:-на GitHub}. Подробности смотрите в описании релиза на GitHub."
    headline="Обновление на GitHub"
  fi

  jq -nc \
    --arg headline "$headline" \
    --arg summary "$summary" \
    --arg name "${name:-}" \
    --argjson features "$features_json" \
    --argjson fixes "$fixes_json" \
    --argjson other "$other_json" \
    --arg raw_excerpt "$(printf '%s' "$raw" | head -c 4000)" \
    '{
      headline:$headline,
      summary:$summary,
      name:(if $name=="" then null else $name end),
      features:$features,
      fixes:$fixes,
      other:$other,
      raw_excerpt:(if $raw_excerpt=="" then null else $raw_excerpt end)
    }'
  rm -rf "$tmp" 2>/dev/null || true
}

ss_version_write() {
  local installed="${1:-$ADDON_VERSION}"
  local latest="${2:-}"
  local tag="${3:-}"
  local url="${4:-}"
  local err="${5:-}"
  local download_url="${6:-}"
  local notes_json="${7:-}"
  local cmp update_available="false"
  ss_ensure_dirs
  if [ -n "$latest" ]; then
    cmp=$(ss_version_cmp "$latest" "$installed")
    [ "$cmp" = "1" ] && update_available="true"
  fi
  # Keep previous download_url / notes if new ones empty
  if [ -z "$download_url" ] && [ -f "$SS_VERSION_FILE" ]; then
    download_url=$(jq -r '.download_url // empty' "$SS_VERSION_FILE" 2>/dev/null)
  fi
  [ -n "$download_url" ] || download_url="$ADDON_RELEASE_TGZ"
  if [ -z "$notes_json" ] || [ "$notes_json" = "null" ]; then
    if [ -f "$SS_VERSION_FILE" ]; then
      notes_json=$(jq -c '.changelog // null' "$SS_VERSION_FILE" 2>/dev/null || echo null)
    else
      notes_json="null"
    fi
  fi
  [ -n "$notes_json" ] || notes_json="null"

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
    --argjson changelog "$notes_json" \
    '{
      installed: $installed,
      latest: (if $latest == "" then null else $latest end),
      tag: (if $tag == "" then null else $tag end),
      release_url: (if $url == "" then null else $url end),
      download_url: $download_url,
      repo: $repo,
      update_available: $update_available,
      checked_at: $checked_at,
      error: (if $err == "" then null else $err end),
      changelog: $changelog
    }' >"$SS_VERSION_FILE"
  ln -sf "$SS_VERSION_FILE" "$ADDON_WEB_DIR/version.json" 2>/dev/null || true
  cat "$SS_VERSION_FILE"
}

ss_version_local() {
  # Always refresh installed field even offline (preserve changelog)
  local prev_latest prev_tag prev_url prev_dl prev_notes
  if [ -f "$SS_VERSION_FILE" ]; then
    prev_latest=$(jq -r '.latest // empty' "$SS_VERSION_FILE" 2>/dev/null)
    prev_tag=$(jq -r '.tag // empty' "$SS_VERSION_FILE" 2>/dev/null)
    prev_url=$(jq -r '.release_url // empty' "$SS_VERSION_FILE" 2>/dev/null)
    prev_dl=$(jq -r '.download_url // empty' "$SS_VERSION_FILE" 2>/dev/null)
    prev_notes=$(jq -c '.changelog // null' "$SS_VERSION_FILE" 2>/dev/null || echo null)
    ss_version_write "$ADDON_VERSION" "$prev_latest" "$prev_tag" "$prev_url" "" "$prev_dl" "$prev_notes"
  else
    ss_version_write "$ADDON_VERSION" "" "" "" "" "$ADDON_RELEASE_TGZ" "null"
  fi
}

ss_version_check() {
  # Query GitHub latest release; update version.json + human changelog
  local resp tag latest url http_code tmp err="" asset="" body name notes
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
        "$(jq -r '.download_url // empty' "$SS_VERSION_FILE")" \
        "$(jq -c '.changelog // null' "$SS_VERSION_FILE")" >/dev/null
    else
      ss_version_write "$ADDON_VERSION" "" "" "" "$err" "$ADDON_RELEASE_TGZ" "null" >/dev/null
    fi
    rm -f "$tmp"
    cat "$SS_VERSION_FILE"
    return 1
  fi

  tag=$(jq -r '.tag_name // empty' "$tmp")
  latest=$(ss_version_normalize "$tag")
  url=$(jq -r '.html_url // empty' "$tmp")
  name=$(jq -r '.name // empty' "$tmp")
  body=$(jq -r '.body // empty' "$tmp")
  asset=$(jq -r '
    (.assets // [])[]
    | select(.name == "asuswrt-merlin-stealthsurf.tar.gz")
    | .browser_download_url
  ' "$tmp" 2>/dev/null | head -1)
  if [ -z "$asset" ]; then
    # Releases without uploaded asset: use /latest/download redirect URL
    asset="$ADDON_RELEASE_TGZ"
  fi

  notes=$(ss_version_humanize_notes "$body" "$tag" "$name" 2>/dev/null || echo null)
  [ -n "$notes" ] || notes="null"

  rm -f "$tmp"
  ss_version_write "$ADDON_VERSION" "$latest" "$tag" "$url" "" "$asset" "$notes" >/dev/null
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
