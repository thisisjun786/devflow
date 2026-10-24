#!/usr/bin/env bash
# Apply only to job launches, never to the user's rg installation/configuration.
search_environment() {
  if [ "${RIPGREP_CONFIG_PATH+x}" = x ]; then
    export RIPGREP_CONFIG_PATH
    return
  fi
  local config glob
  config=$(mktemp "$S/ripgrep.XXXXXX") || return 1
  {
    printf '%s\n' "--max-filesize=$DV_RG_MAX_FILESIZE" "--max-columns=$DV_RG_MAX_COLUMNS"
    while IFS= read -r glob; do
      [ -z "$glob" ] || printf '%s\n' "--glob=$glob"
    done <<< "$DV_RG_EXCLUDE_GLOBS"
  } > "$config"
  export RIPGREP_CONFIG_PATH="$config"
}
