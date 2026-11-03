#!/bin/bash
#
####
# - HTTP(S)-Ping -
# check an URL until the expected text appears in the response body
#
# v1.1 2026-08-12 /GitHub Copilot
####

## 0 - constants, variables, settings
VER="1.1"

debug=0
deadtime=5
interval=5
fuzzy_limit=0
follow=1
health=2
transmitted=0
received=0
uptotal=0
downtotal=0
upsec=0
downsec=0
missingtotal=0
lastuptime=0
lastdowntime=0
lastmissingtime=0
flap=0
fuzzy_total=0
fuzzy_lost=0
fuzzy_cnt=0
expected_text=""
target_url=""
unsecure=0
port=""
last_http_code="000"
last_response_time="0.000"
last_response_time_ms=0
success_response_total="0.000"
success_response_count=0
avg_response_time="0.000"
ok_response_total_ms=0
ok_response_count=0
ok_response_min_ms=0
ok_response_max_ms=0
missing_response_total_ms=0
missing_response_count=0
missing_response_min_ms=0
missing_response_max_ms=0

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
ORANGE=$'\033[0;33m'
RESET=$'\033[0m'

usage () {
  echo -e "usage: $(basename "$0") [-d] [-W deadtime] [-i interval] [-f fuzzy-pings] [-u] [-P port] [-t text] <URL>"
  echo -e "\t-u  use HTTP instead of the default HTTPS"
  echo -e "\t-P  port override"
  echo -e "\t-t  optional expected text to find in the HTTP response body (default: accept HTTP 200 only)"
  echo -e "\t-W  HTTP timeout in seconds (default: 5)"
  echo -e "\t-i  seconds between checks (default: 5)"
  echo -e "\t-f  failed checks before marking down; 0 disables (default: 0)"
  echo -e "\t-d  debug output"
  echo -e "\t-v  show version"
  echo -e "\t-h  show help"
  echo -e "\nExamples:"
  echo -e "\t$(basename "$0") https://example.com/login"
  echo -e "\t$(basename "$0") -t \"Welcome\" https://example.com/login"
  echo -e "\t$(basename "$0") -u -P 8080 -t \"OK\" example.com"
}

# parse options
_options () {
  while getopts ":dW:i:f:uP:t:hv" opt; do
    case $opt in
      d ) debug=1 ;;
      W ) deadtime=$OPTARG ;;
      i ) interval=$OPTARG ;;
      f ) fuzzy_limit=$OPTARG ;;
      u ) unsecure=1 ;;
      P ) port=$OPTARG ;;
      t ) expected_text=$OPTARG ;;
      v ) echo "$(basename "$0") v$VER"; exit 0 ;;
      h ) usage; exit 0 ;;
      \? )
        echo "Invalid option: -$OPTARG" >&2
        usage
        exit 1 ;;
      : )
        echo "Option -$OPTARG requires an argument." >&2
        usage
        exit 1 ;;
    esac
  done
  shift $((OPTIND - 1))

  if [[ -z "$1" ]]; then
    usage
    exit 1
  fi

  target_url=$1
}

function displaytime {
  local T=$1
  local D=$((T/60/60/24))
  local H=$((T/60/60%24))
  local M=$((T/60%60))
  local S=$((T%60))
  [[ $D -gt 0 ]] && printf '%d d ' $D
  [[ $H -gt 0 ]] && printf '%d h ' $H
  [[ $M -gt 0 ]] && printf '%d min ' $M
  [[ $D -gt 0 || $H -gt 0 || $M -gt 0 ]] && printf 'and '
  printf '%d sec\n' $S
}

# Parse URL, protocol and port. HTTPS is the default; -u selects HTTP.
normalize_url () {
  local raw_url="$1"
  local scheme="https"
  local hostport=""
  local path="/"
  local host=""
  local portvalue=""
  local parsed_url=""

  if [[ "$unsecure" -eq 1 ]]; then
    scheme="http"
  fi

  if [[ "$raw_url" =~ ^https?:// ]]; then
    parsed_url="$raw_url"
  else
    parsed_url="${scheme}://${raw_url}"
  fi

  local remainder="${parsed_url#*://}"
  if [[ "$remainder" == "$parsed_url" ]]; then
    echo "Invalid URL: $raw_url" >&2
    exit 1
  fi

  hostport="${remainder%%/*}"
  if [[ "$remainder" == *"/"* ]]; then
    path="/${remainder#*/}"
  fi
  if [[ -z "$path" || "$path" == "$remainder" ]]; then
    path="/"
  fi

  if [[ "$hostport" == *":"* ]]; then
    host="${hostport%:*}"
    portvalue="${hostport##*:}"
  else
    host="$hostport"
  fi

  if [[ -n "$port" ]]; then
    case "${port,,}" in
      http) portvalue=80 ;;
      https) portvalue=443 ;;
      *) portvalue="$port" ;;
    esac
  fi

  if [[ -z "$portvalue" ]]; then
    if [[ "$scheme" == "https" ]]; then
      portvalue=443
    else
      portvalue=80
    fi
  fi

  if [[ "$host" == "" ]]; then
    echo "Host is missing from URL: $raw_url" >&2
    exit 1
  fi

  printf '%s://%s:%s%s\n' "$scheme" "$host" "$portvalue" "$path"
}

check_url () {
  local url="$1"
  local body_file=$(mktemp)
  local headers_file=$(mktemp)
  local meta_file=$(mktemp)
  local http_code="000"
  local total_time="0.000"

  last_http_code="000"
  last_response_time="0.000"
  last_response_time_ms=0

  if ! curl -sSL -L --connect-timeout "$deadtime" --max-time "$deadtime" -D "$headers_file" -o "$body_file" -w '\n%{http_code} %{time_total}' "$url" > "$meta_file" 2>/dev/null; then
    rm -f "$body_file" "$headers_file" "$meta_file"
    return 1
  fi

  read -r http_code total_time <<< "$(tail -n 1 "$meta_file" 2>/dev/null)"
  http_code="${http_code:-000}"
  total_time="${total_time:-0.000}"

  last_http_code="$http_code"
  last_response_time="$total_time"
  last_response_time_ms=$(awk -v value="$last_response_time" 'BEGIN { printf "%d", value * 1000 }')

  if [[ "$http_code" != "200" ]]; then
    rm -f "$body_file" "$headers_file" "$meta_file"
    return 1
  fi

  if [[ -n "$expected_text" ]] && ! grep -Fq -- "$expected_text" "$body_file"; then
    record_response_time missing "$last_response_time_ms"
    rm -f "$body_file" "$headers_file" "$meta_file"
    return 2
  fi

  record_response_time ok "$last_response_time_ms"
  success_response_total=$(awk -v a="$success_response_total" -v b="$last_response_time" 'BEGIN { printf "%.6f", a + b }')
  success_response_count=$((success_response_count + 1))
  avg_response_time=$(awk -v total="$success_response_total" -v count="$success_response_count" 'BEGIN { if (count > 0) printf "%.3f", total / count; else printf "0.000"; }')

  rm -f "$body_file" "$headers_file" "$meta_file"
  return 0
}

record_response_time () {
  local state="$1"
  local duration_ms="$2"
  case "$state" in
    ok)
      ok_response_total_ms=$((ok_response_total_ms + duration_ms))
      ok_response_count=$((ok_response_count + 1))
      if [[ "$ok_response_min_ms" -eq 0 || "$duration_ms" -lt "$ok_response_min_ms" ]]; then ok_response_min_ms="$duration_ms"; fi
      if [[ "$duration_ms" -gt "$ok_response_max_ms" ]]; then ok_response_max_ms="$duration_ms"; fi
      ;;
    missing)
      missing_response_total_ms=$((missing_response_total_ms + duration_ms))
      missing_response_count=$((missing_response_count + 1))
      if [[ "$missing_response_min_ms" -eq 0 || "$duration_ms" -lt "$missing_response_min_ms" ]]; then missing_response_min_ms="$duration_ms"; fi
      if [[ "$duration_ms" -gt "$missing_response_max_ms" ]]; then missing_response_max_ms="$duration_ms"; fi
      ;;
  esac
}

print_response_statistics () {
  local label="$1"
  local total_ms="$2"
  local count="$3"
  local min_ms="$4"
  local max_ms="$5"
  if [[ "$count" -gt 0 ]]; then
    echo "$label response time min/avg/max = ${min_ms}ms/$(awk -v total="$total_ms" -v count="$count" 'BEGIN { printf "%d", total / count }')ms/${max_ms}ms"
  else
    echo "$label response time min/avg/max = n/a"
  fi
}

print_statistics () {
  echo -e "\n--- $target_url http-check statistics ---"

  if [[ $health -eq 1 ]]; then
    upsec=$(date +%s)-$lastuptime
    uptotal=$((uptotal + upsec))
  elif [[ $health -eq 0 ]]; then
    downsec=$(date +%s)-$lastdowntime
    downtotal=$((downtotal + downsec))
  elif [[ $health -eq 3 ]]; then
    missingsec=$(date +%s)-$lastmissingtime
    missingtotal=$((missingtotal + missingsec))
  fi

  echo "flapped $flap times, was up for $(displaytime $uptotal) and down for $(displaytime $downtotal)"
  echo "was missing expected text for $(displaytime $missingtotal)"
  echo "$transmitted requests sent, $received successful checks, $((100 - (received * 100 / transmitted)))% failed"
  print_response_statistics ok "$ok_response_total_ms" "$ok_response_count" "$ok_response_min_ms" "$ok_response_max_ms"
  print_response_statistics missing "$missing_response_total_ms" "$missing_response_count" "$missing_response_min_ms" "$missing_response_max_ms"
  exit 0
}

trap print_statistics INT

# runtime execution
_options "$@"

if [[ -n "$debug" && "$debug" -eq 1 ]]; then
  echo -e "\t####### DEBUG #######"
  echo -e "\turl = [ $target_url ]"
  if [[ "$unsecure" -eq 1 ]]; then
    echo -e "\tprotocol = [ http ]"
  else
    echo -e "\tprotocol = [ https ]"
  fi
  echo -e "\tport = [ ${port:-auto} ]"
  echo -e "\ttext = [ ${expected_text:-not set} ]"
  echo -e "\tdeadtime = [ $deadtime ]"
  echo -e "\tinterval = [ $interval ]"
  echo -e "\t####### DEBUG #######"
fi

normalized_target=$(normalize_url "$target_url")

status_line_started=0
write_status () {
  local message="$1"
  local new_line="${2:-0}"
  if [[ "$new_line" -eq 1 && "$status_line_started" -eq 1 ]]; then
    printf '\n'
  fi
  printf '\r\033[K%s' "$message"
  status_line_started=1
}

while :; do
  transmitted=$((transmitted + 1))

  check_url "$normalized_target"
  check_result=$?
  if [[ "$check_result" -eq 0 ]]; then
    received=$((received + 1))
    text_suffix=""
    if [[ -n "$expected_text" ]]; then
      text_suffix=" | response contains '$expected_text'"
    fi

    if [[ $health -eq 2 ]]; then
      lastuptime=$(date +%s)
      write_status "$(date +'%Y-%m-%d %H:%M:%S') | url $normalized_target is ${GREEN}ok${RESET} [HTTP $last_http_code, ${last_response_time_ms}ms]${text_suffix}" 1
      health=1
    elif [[ $health -eq 0 ]]; then
      downsec=$(date +%s)-$lastdowntime
      downtotal=$((downtotal + downsec))
      flap=$((flap + 1))
      write_status "$(date +'%Y-%m-%d %H:%M:%S') | url $normalized_target is ${GREEN}ok${RESET} [down for $(displaytime "$downsec")] [HTTP $last_http_code, ${last_response_time_ms}ms]${text_suffix}" 1
      lastuptime=$(date +%s)
      health=1
    elif [[ $health -eq 3 ]]; then
      missingsec=$(date +%s)-$lastmissingtime
      missingtotal=$((missingtotal + missingsec))
      flap=$((flap + 1))
      write_status "$(date +'%Y-%m-%d %H:%M:%S') | url $normalized_target is ${GREEN}ok${RESET} [missing for $(displaytime "$missingsec")] [HTTP $last_http_code, ${last_response_time_ms}ms]${text_suffix}" 1
      lastuptime=$(date +%s)
      health=1
    elif [[ $health -eq 1 ]] && [[ $follow -eq 1 ]]; then
      upsec=$(date +%s)-$lastuptime
      write_status "$(date +'%Y-%m-%d %H:%M:%S') | url $normalized_target is ${GREEN}ok${RESET} for $(displaytime "$upsec") [HTTP $last_http_code, ${last_response_time_ms}ms]${text_suffix}"
    fi

    if [[ $fuzzy_limit -gt 0 ]] && [[ $fuzzy_cnt -gt 0 ]]; then
      fuzzy_total=$((fuzzy_total + 1))
      fuzzy_lost=$((fuzzy_lost + fuzzy_cnt))
    fi
    fuzzy_cnt=0
    sleep "$interval"
    continue
  fi

  if [[ "$check_result" -eq 2 ]]; then
    fuzzy_cnt=0
    if [[ $health -eq 1 ]]; then
      upsec=$(date +%s)-$lastuptime
      uptotal=$((uptotal + upsec))
      flap=$((flap + 1))
      lastmissingtime=$(date +%s)
      write_status "$(date +'%Y-%m-%d %H:%M:%S') | url $normalized_target is ${ORANGE}missing${RESET} [HTTP $last_http_code, ${last_response_time_ms}ms] | response misses '$expected_text'" 1
    elif [[ $health -eq 0 ]]; then
      downsec=$(date +%s)-$lastdowntime
      downtotal=$((downtotal + downsec))
      flap=$((flap + 1))
      lastmissingtime=$(date +%s)
      write_status "$(date +'%Y-%m-%d %H:%M:%S') | url $normalized_target is ${ORANGE}missing${RESET} [down for $(displaytime "$downsec")] [HTTP $last_http_code, ${last_response_time_ms}ms] | response misses '$expected_text'" 1
    elif [[ $health -eq 3 ]]; then
      missingsec=$(date +%s)-$lastmissingtime
      write_status "$(date +'%Y-%m-%d %H:%M:%S') | url $normalized_target is ${ORANGE}missing${RESET} for $(displaytime "$missingsec") [HTTP $last_http_code, ${last_response_time_ms}ms] | response misses '$expected_text'"
    else
      lastmissingtime=$(date +%s)
      write_status "$(date +'%Y-%m-%d %H:%M:%S') | url $normalized_target is ${ORANGE}missing${RESET} [HTTP $last_http_code, ${last_response_time_ms}ms] | response misses '$expected_text'" 1
    fi
    health=3
    sleep "$interval"
    continue
  fi

  fuzzy_cnt=$((fuzzy_cnt + 1))
  if [[ $fuzzy_cnt -gt "$fuzzy_limit" ]]; then
    if [[ $health -eq 2 ]]; then
      lastdowntime=$(date +%s)
      write_status "$(date +'%Y-%m-%d %H:%M:%S') | url $normalized_target is ${RED}down${RESET} [HTTP $last_http_code]" 1
      health=0
    elif [[ $health -eq 1 ]]; then
      lastdowntime=$(date +%s)
      upsec=$(date +%s)-$lastuptime
      uptotal=$((uptotal + upsec))
      flap=$((flap + 1))
      write_status "$(date +'%Y-%m-%d %H:%M:%S') | url $normalized_target is ${RED}down${RESET} [ok for $(displaytime "$upsec")] [HTTP $last_http_code]" 1
      health=0
    elif [[ $health -eq 3 ]]; then
      missingsec=$(date +%s)-$lastmissingtime
      missingtotal=$((missingtotal + missingsec))
      lastdowntime=$(date +%s)
      flap=$((flap + 1))
      write_status "$(date +'%Y-%m-%d %H:%M:%S') | url $normalized_target is ${RED}down${RESET} [missing for $(displaytime "$missingsec")] [HTTP $last_http_code]" 1
      health=0
    elif [[ $health -eq 0 ]] && [[ $follow -eq 1 ]]; then
      downsec=$(date +%s)-$lastdowntime
      write_status "$(date +'%Y-%m-%d %H:%M:%S') | url $normalized_target is ${RED}down${RESET} for $(displaytime "$downsec") [HTTP $last_http_code]"
    fi
  else
    if [[ $fuzzy_cnt -eq 1 ]]; then
      echo -n " --FUZZY--"
    fi
  fi

  sleep "$interval"
done
