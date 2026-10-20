#!/usr/bin/env bash
# Codex onboarding reads persisted project trust, not CLI -c overrides.
# shellcheck disable=SC2016
codex_config_info() {
  local config="${CODEX_HOME:-$HOME/.codex}/config.toml"
  if [ ! -e "$config" ]; then printf '{"provider":"openai","env_keys":{},"projects":{}}\n'; return; fi
  # Read the scalar/table forms written by Codex, including quoted/literal keys
  # and dotted assignments. Refuse ambiguous forms instead of rewriting TOML.
  # Basic strings are decoded by jq; unsupported TOML escapes fail closed.
  awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
    function quote(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); return "\"" s "\"" }
    function bad() { exit 1 }
    function keys(s,    out,c,q,t,i) {
      out=""; s=trim(s)
      while (length(s)) {
        c=substr(s,1,1); t=""
        if (c=="\"" || c==sprintf("%c",39)) {
          q=c
          for (i=2;i<=length(s);i++) {
            c=substr(s,i,1)
            if (q=="\"" && c=="\\") { t=t c substr(s,++i,1); continue }
            if (c==q) break
            t=t c
          }
          if (i>length(s)) bad()
          if (q=="\"") t="\"" t "\""; else t=quote(t)
          s=trim(substr(s,i+1))
        } else {
          if (!match(s,/^[A-Za-z0-9_-]+/)) bad()
          t=quote(substr(s,1,RLENGTH)); s=trim(substr(s,RLENGTH+1))
        }
        out=out (out=="" ? "" : ",") t
        if (s=="") break
        if (substr(s,1,1)!=".") bad()
        s=trim(substr(s,2)); if (s=="") bad()
      }
      return out
    }
    {
      # Strip comments and find the assignment delimiter outside strings.
      line=""; q=""; equal=0
      for (i=1;i<=length($0);i++) {
        c=substr($0,i,1)
        if (q!="") {
          line=line c
          if (q=="\"" && c=="\\") { line=line substr($0,++i,1); continue }
          if (c==q) q=""
        } else {
          if (c=="#") break
          if (c=="\"" || c==sprintf("%c",39)) {
            if (substr($0,i,3)==c c c) bad()
            q=c
          }
          if (c=="=" && !equal) equal=length(line)+1
          line=line c
        }
      }
      if (q!="") bad()
      clean=line; line=trim(line); if (line=="") next
      if (substr(line,1,1)=="[") {
        array=(substr(line,1,2)=="[[")
        n=(array ? 2 : 1)
        if (substr(line,length(line)-n+1)!= (array ? "]]" : "]")) bad()
        section=keys(substr(line,n+1,length(line)-2*n))
        if (section ~ /^"projects",/) print "{\"path\":[" section "],\"value\":\"__section__\"}"
        next
      }
      if (!equal) next
      value=trim(substr(clean,equal+1))
      raw=substr(clean,1,equal-1)
      path=keys(raw); if (section!="") path=section "," path
      relevant=(path ~ /^"model_provider"$/ || path ~ /^"model_providers"/ || path ~ /^"projects"/)
      if (!relevant) next
      if (array) bad()
      if (path ~ /^"model_providers",[^,]+,"[^" ]+"$/ && path !~ /,"env_key"$/) next
      if (path ~ /^"projects",.+,"[^" ]+"$/ && path !~ /,"trust_level"$/) next
      c=substr(value,1,1)
      if (c==sprintf("%c",39) && substr(value,length(value))==c) value=quote(substr(value,2,length(value)-2))
      else if (c!="\"" || substr(value,length(value))!="\"") bad()
      print "{\"path\":[" path "],\"value\":" value "}"
    }
  ' "$config" | jq -s '
    reduce .[] as $entry ({provider:"openai",env_keys:{},projects:{}};
      $entry.path as $p |
      if ($entry.value|type)!="string" then error("expected a string")
      elif $p==["model_provider"] then .provider=$entry.value
      elif ($p|length)==3 and $p[0]=="model_providers" and $p[2]=="env_key" then .env_keys[$p[1]]=$entry.value
      elif ($p|length)==2 and $p[0]=="projects" and $entry.value=="__section__" then .projects[$p[1]]=(.projects[$p[1]] // "unspecified")
      elif ($p|length)==3 and $p[0]=="projects" and $p[2]=="trust_level" then .projects[$p[1]]=$entry.value
      else error("unsupported provider/project configuration") end)
  '
}
codex_environment() {
  # Read the host-local operator file in both the bid and terminal process.
  # Never serialize credentials into pane commands, metadata or logs.
  if [ -f "$DV_CODEX_ENV_FILE" ]; then
    # shellcheck source=/dev/null
    source "$DV_CODEX_ENV_FILE" || return 1
  fi
  local info key
  info=$(codex_config_info) || { printf 'dv: unsupported Codex config; cannot check provider/trust safely\n' >&2; return 1; }
  key=$(printf '%s\n' "$info" | jq -r '.env_keys[.provider] // empty')
  if [ -n "$key" ]; then
    if ! [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then printf 'dv: invalid Codex provider env_key\n' >&2; return 1; fi
    if [ -z "${!key:-}" ]; then printf 'dv: missing Codex provider environment variable: %s\n' "$key" >&2; return 1; fi
    export "${key?}"
  fi
}
codex_repo_root() (
  cd "$1" || return 1
  local common
  common=$(git rev-parse --git-common-dir) || return 1
  cd "$common/.." && pwd -P
)
codex_repo_allowed() {
  local root=$1 allowed canonical
  root=$(codex_canonical_path "$root") || return 1
  while IFS= read -r allowed; do
    [ -n "$allowed" ] || continue
    [[ "$allowed" = /* ]] || continue
    canonical=$(codex_canonical_path "$allowed") || continue
    [ "$canonical" != "$root" ] || return 0
  done <<< "$DV_TRUSTED_REPOS"
  printf 'dv: Codex repository is not in DV_TRUSTED_REPOS: %s\n' "$root" >&2
  return 1
}
codex_canonical_path() (
  # Bids may refer to an allowlisted clone destination that does not exist yet.
  local path=$1 parent name
  [[ "$path" = /* && "$path" != *$'\n'* ]] || return 1
  if [ -d "$path" ]; then cd "$path" && pwd -P; return; fi
  [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  parent=$(codex_canonical_path "$(dirname "$path")") || return 1
  name=$(basename "$path")
  case "$name" in .) printf '%s\n' "$parent" ;; ..) dirname "$parent" ;; *) printf '%s/%s\n' "${parent%/}" "$name" ;; esac
)
codex_trust_repo() (
  local root=$1 config_dir="${CODEX_HOME:-$HOME/.codex}" config lock info trust tries=0
  codex_repo_allowed "$root" || return 1
  umask 077
  mkdir -p "$config_dir" || return 1
  config="$config_dir/config.toml"; lock="$config_dir/.dv-trust-lock"
  until mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1)); [ "$tries" -lt 100 ] || { printf 'dv: Codex trust config busy\n' >&2; return 1; }
    sleep 0.1
  done
  trap 'rmdir "$lock"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  if [ -L "$config" ] || { [ -e "$config" ] && [ ! -f "$config" ]; }; then
    printf 'dv: Codex config must be a regular file\n' >&2; return 1
  fi
  info=$(codex_config_info) || { printf 'dv: unsupported Codex config; trust was not changed\n' >&2; return 1; }
  trust=$(printf '%s\n' "$info" | jq -r --arg root "$root" '.projects[$root] // empty')
  case "$trust" in
    trusted) return 0 ;;
    '') ;;
    *) printf 'dv: existing Codex trust is %s; operator must resolve it: %s\n' "$trust" "$root" >&2; return 1 ;;
  esac
  # Append only. Preserve every existing byte; never replace operator decisions.
  printf '\n[projects.%s]\ntrust_level = "trusted"\n' "$(jq -Rn --arg path "$root" '$path')" >> "$config"
)
