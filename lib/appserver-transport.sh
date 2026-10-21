#!/usr/bin/env bash
# Codex proxy forwards raw Unix socket bytes. The control socket speaks
# WebSocket, not JSONL. Keep framing separate from job/delivery semantics.
# shellcheck disable=SC2016
appserver_ws_accept() {
  printf '%s258EAFA5-E914-47DA-95CA-C5AB0DC85B11' "$1" |
    openssl dgst -sha1 -binary | openssl base64 -A
}
appserver_ws_upgrade() {
  local key expected line status='' accept='' upgrade='' connection='' deadline complete=0
  key=$(openssl rand -base64 16) || return 1
  expected=$(appserver_ws_accept "$key") || return 1
  printf 'GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n' "$key" >&7
  deadline=$(( $(date +%s) + DV_APPSERVER_TIMEOUT ))
  while [ "$(date +%s)" -le "$deadline" ]; do
    IFS= read -r -t 1 line <&6 || continue
    line=${line%$'\r'}
    if [ -z "$status" ]; then status=$line; continue; fi
    if [ -z "$line" ]; then complete=1; break; fi
    case "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]')" in
      sec-websocket-accept:*) accept=${line#*:}; accept=$(printf '%s' "$accept" | tr -d ' \t') ;;
      upgrade:*) upgrade=$(printf '%s' "${line#*:}" | tr -d ' \t' | tr '[:upper:]' '[:lower:]') ;;
      connection:*) connection=$(printf '%s' "${line#*:}" | tr '[:upper:]' '[:lower:]') ;;
    esac
  done
  [ "$complete" = 1 ] && [[ "$status" = 'HTTP/1.1 101 '* ]] && [ "$accept" = "$expected" ] && [ "$upgrade" = websocket ] && [[ "$connection" = *upgrade* ]]
}
appserver_ws_byte() { printf '%b' "\\$(printf '%03o' "$1")"; }
appserver_ws_mask() {
  # POSIX awk has no xor operator. Work in the C locale, including NUL bytes.
  LC_ALL=C od -An -v -tu1 "$1" | LC_ALL=C awk -v key="$2" '
    function byte_xor(a,b, r,p) { r=0;p=1;while(a||b){if(a%2!=b%2)r+=p;a=int(a/2);b=int(b/2);p*=2}return r }
    BEGIN { split(key,k); n=0 }
    { for(i=1;i<=NF;i++){printf "%c",byte_xor($i,k[n%4+1]);n++} }'
}
appserver_ws_frame() {
  local file=$1 opcode=$2 masked=$3 length key='' byte shiftbits
  length=$(wc -c < "$file" | tr -d ' ')
  [ "$length" -le 16777216 ] || return 1
  appserver_ws_byte "$((128 + opcode))"
  if [ "$length" -lt 126 ]; then appserver_ws_byte "$((masked * 128 + length))"
  elif [ "$length" -le 65535 ]; then
    appserver_ws_byte "$((masked * 128 + 126))"
    appserver_ws_byte "$((length / 256))"; appserver_ws_byte "$((length % 256))"
  else
    appserver_ws_byte "$((masked * 128 + 127))"
    printf '\000\000\000\000'
    for shiftbits in 24 16 8 0; do appserver_ws_byte "$(((length >> shiftbits) & 255))"; done
  fi
  if [ "$masked" = 1 ]; then
    key=$(openssl rand 4 | od -An -v -tu1)
    for byte in $key; do appserver_ws_byte "$byte"; done
    appserver_ws_mask "$file" "$key"
  else cat "$file"; fi
}
appserver_ws_send() {
  local masked=$1 line rc file pending=''
  while :; do
    rc=0
    IFS= read -r -t 1 line || rc=$?
    pending=$pending$line
    if [ "$rc" = 0 ]; then
      printf '%s' "$pending" > "$AS_IO/send.payload"
      appserver_ws_frame "$AS_IO/send.payload" 1 "$masked" || return 1
      pending=''
    elif [ "$rc" -le 128 ]; then return 0; fi
    for file in "$AS_IO"/pong.*.ready; do
      [ -f "$file" ] || continue
      appserver_ws_frame "$file" 10 "$masked" || return 1
      rm -f "$file" "${file%.ready}"
    done
  done
}
appserver_ws_bytes() {
  local remaining=$1 target=$2 before after
  : > "$target"
  while [ "$remaining" -gt 0 ]; do
    before=$(wc -c < "$target")
    dd bs="$remaining" count=1 >> "$target" 2>/dev/null || return 1
    after=$(wc -c < "$target")
    [ "$after" -gt "$before" ] || return 1
    remaining=$((remaining - after + before))
  done
}
appserver_ws_receive() {
  local masked=$1 header first second opcode final length byte key file fragmented=0 total=0
  : > "$AS_IO/message"
  while :; do
    appserver_ws_bytes 2 "$AS_IO/header" || return 1
    header=$(od -An -v -tu1 "$AS_IO/header")
    read -r first second <<< "$header"
    [ "$((first & 112))" = 0 ] && [ "$((second / 128))" = "$masked" ] || return 1
    opcode=$((first & 15)); final=$((first / 128)); length=$((second & 127))
    if [ "$length" -ge 126 ]; then
      if [ "$length" = 126 ]; then byte=2; else byte=8; fi
      appserver_ws_bytes "$byte" "$AS_IO/length" || return 1
      length=0
      for byte in $(od -An -v -tu1 "$AS_IO/length"); do
        length=$((length * 256 + byte)); [ "$length" -le 16777216 ] || return 1
      done
    fi
    [ "$opcode" -lt 8 ] || { [ "$length" -le 125 ] && [ "$final" = 1 ]; } || return 1
    key=''
    if [ "$masked" = 1 ]; then
      appserver_ws_bytes 4 "$AS_IO/mask" || return 1
      key=$(od -An -v -tu1 "$AS_IO/mask")
    fi
    appserver_ws_bytes "$length" "$AS_IO/received" || return 1
    if [ "$masked" = 1 ]; then appserver_ws_mask "$AS_IO/received" "$key" > "$AS_IO/payload"
    else mv "$AS_IO/received" "$AS_IO/payload"; fi
    case "$opcode" in
      8) return 0 ;;
      9) file=$(mktemp "$AS_IO/pong.XXXXXX"); mv "$AS_IO/payload" "$file.ready"; continue ;;
      10) continue ;;
      1) [ "$fragmented" = 0 ] || return 1; fragmented=1 ;;
      0) [ "$fragmented" = 1 ] || return 1 ;;
      *) return 1 ;;
    esac
    total=$((total + length)); [ "$total" -le 16777216 ] || return 1
    cat "$AS_IO/payload" >> "$AS_IO/message"
    if [ "$final" = 1 ]; then
      cat "$AS_IO/message"; printf '\n'
      : > "$AS_IO/message"; fragmented=0; total=0
    fi
  done
}
