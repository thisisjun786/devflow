#!/usr/bin/env bash
# One atomic record binds the response body to its validator. Concurrent
# readers keep their own snapshot, so a 304 cannot pick up another body's tag.
gh_get_cached() (
  umask 077
  local endpoint=$1 host=${GH_HOST:-github.com} key file cached='' etag='' work code rc=0 immutable=false
  local headers=()
  key=$(printf '%s\n%s' "$host" "$endpoint" | cksum | awk '{print $1 "-" $2}')
  mkdir -p "$DV_HOME/gh-cache" || return 1
  file="$DV_HOME/gh-cache/$key.json"
  if [ -f "$file" ]; then
    cached=$(jq -ce --arg host "$host" --arg endpoint "$endpoint" \
      'select(.host==$host and .endpoint==$endpoint and (.body|type)=="string" and (.etag|type)=="string")' "$file") || cached=''
  fi
  if [[ "$endpoint" =~ ^repos/[^/]+/[^/]+/compare/[0-9a-f]{40}\.\.\.[0-9a-f]{40}$ ]]; then immutable=true; fi
  if [ -n "$cached" ]; then
    if [ "$immutable" = true ]; then jq -j .body <<< "$cached"; return; fi
    etag=$(jq -r .etag <<< "$cached")
    [ -z "$etag" ] || headers=(-H "If-None-Match: $etag")
  fi
  work=$(mktemp -d "$DV_HOME/gh-cache/.get.XXXXXX") || return 1
  trap 'rm -rf "$work"' EXIT
  gh api --include "$endpoint" ${headers[@]+"${headers[@]}"} > "$work/response" || rc=$?
  code=$(awk '/^HTTP\// {print $2; exit}' "$work/response")
  if [ "$code" = 304 ]; then
    [ -n "$cached" ] && [ -n "$etag" ] || return 1
    jq -j .body <<< "$cached"; return
  fi
  [ "$rc" = 0 ] && [ "$code" = 200 ] || return 1
  awk 'body {print; next} /^\r?$/ {body=1}' "$work/response" > "$work/body"
  jq -e 'type=="array" or type=="object"' "$work/body" >/dev/null || return 1
  etag=$(awk '/^\r?$/ {exit} tolower($1)=="etag:" {sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}' "$work/response")
  jq -n --arg host "$host" --arg endpoint "$endpoint" --arg etag "$etag" --rawfile body "$work/body" \
    '{host:$host,endpoint:$endpoint,etag:$etag,body:$body}' > "$work/entry" || return 1
  mv "$work/entry" "$file" || return 1
  cat "$work/body"
)
# Every page is revalidated, including the first short/empty page. Changes
# across page boundaries therefore cannot leave a stale tail in the snapshot.
gh_get_cached_pages() (
  local endpoint=$1 page=1 body work
  mkdir -p "$DV_HOME" || return 1
  work=$(mktemp -d "$DV_HOME/.gh-pages.XXXXXX") || return 1
  trap 'rm -rf "$work"' EXIT
  while :; do
    body=$(gh_get_cached "$endpoint?per_page=100&page=$page") || return 1
    jq -e 'type=="array"' <<< "$body" >/dev/null || return 1
    printf '%s\n' "$body" >> "$work/pages"
    [ "$(jq length <<< "$body")" = 100 ] || break
    page=$((page + 1))
  done
  jq -s 'add // []' "$work/pages"
)
