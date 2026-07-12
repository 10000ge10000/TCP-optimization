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

extract_json_object_text() {
  awk '
    BEGIN { depth=0; started=0; in_string=0; escaped=0; out="" }
    {
      text = text $0 "\n"
    }
    END {
      for (i = 1; i <= length(text); i++) {
        ch = substr(text, i, 1)
        if (!started) {
          if (ch == "{") {
            started = 1
            depth = 1
            out = ch
          }
          continue
        }
        out = out ch
        if (escaped) {
          escaped = 0
          continue
        }
        if (ch == "\\") {
          escaped = 1
          continue
        }
        if (ch == "\"") {
          in_string = !in_string
          continue
        }
        if (!in_string && ch == "{") depth++
        if (!in_string && ch == "}") {
          depth--
          if (depth == 0) {
            print out
            exit 0
          }
        }
      }
      exit 1
    }
  '
}

json_number_field() {
  field="$1"
  default="$2"
  awk -v field="\"$field\"" -v default="$default" '
    BEGIN { value = default }
    {
      pos = index($0, field)
      if (pos) {
        rest = substr($0, pos + length(field))
        sub(/^[^:]*:/, "", rest)
        if (match(rest, /-?[0-9]+/)) value = substr(rest, RSTART, RLENGTH)
      }
    }
    END { print value }
  '
}

json_string_field() {
  field="$1"
  default="$2"
  awk -v field="\"$field\"" -v default="$default" '
    BEGIN { value = default }
    {
      pos = index($0, field)
      if (pos) {
        rest = substr($0, pos + length(field))
        sub(/^[^:]*:[[:space:]]*"/, "", rest)
        end = index(rest, "\"")
        if (end > 0) value = substr(rest, 1, end - 1)
      }
    }
    END { print value }
  '
}

clamp_int() {
  value="$1"
  default="$2"
  min="$3"
  max="$4"
  is_integer "$value" || value="$default"
  awk -v value="$value" -v min="$min" -v max="$max" 'BEGIN {
    if (value < min) value = min
    if (value > max) value = max
    printf "%.0f\n", value
  }'
}
