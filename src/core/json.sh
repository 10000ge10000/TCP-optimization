# Module: src/core/json.sh
json_escape_string() {
  awk '
    BEGIN { first = 1; bs = sprintf("%c", 8); ff = sprintf("%c", 12) }
    {
      gsub(/\\/,"\\\\")
      gsub(/"/,"\\\"")
      gsub(bs,"\\b")
      gsub(ff,"\\f")
      gsub(/\r/,"\\r")
      gsub(/\t/,"\\t")
      if (!first) printf "\\n"
      printf "%s", $0
      first = 0
    }
  '
}

json_string() {
  printf '"%s"' "$(printf '%s' "${1:-}" | json_escape_string)"
}

json_envelope() {
  ok="$1"
  command_name="$2"
  data_json="${3:-null}"
  errors_json="${4:-[]}"
  printf '{"schema_version":1,"ok":%s,"command":%s,"data":%s,"errors":%s}\n' \
    "$ok" "$(json_string "$command_name")" "$data_json" "$errors_json"
}

