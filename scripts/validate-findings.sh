#!/usr/bin/env bash
# Validate findings.json against schema/findings.schema.json with jq only.
#
# Usage: validate-findings.sh <findings.json> [schema.json]
#
# Prints one violation per line as "<json-path>: <problem>" and exits 1 if
# there are any (2 on usage errors). The checks are driven by the schema
# itself; this supports the subset of JSON Schema the findings schema uses:
# type (incl. arrays of types / "null"), const, enum, required, properties,
# additionalProperties: false, items, minimum. Unsupported keywords are
# reported on stderr so a schema change can't be silently ignored.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "usage: $0 <findings.json> [schema.json]" >&2
  exit 2
fi

findings=$1
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
schema=${2:-$here/../schema/findings.schema.json}

if [[ ! -f $schema ]]; then
  echo "schema not found: $schema" >&2
  exit 2
fi
if [[ ! -f $findings ]]; then
  echo "\$: file not found: $findings"
  exit 1
fi
# Exactly one JSON document.
if ! n=$(jq -n '[inputs] | length' "$findings" 2>/dev/null); then
  echo "\$: not valid JSON"
  exit 1
fi
if [[ $n != 1 ]]; then
  echo "\$: expected exactly one JSON document, found $n"
  exit 1
fi

# shellcheck disable=SC2016  # jq program, not shell
validator='
  def path_join($p; $k):
    if ($k | test("^[A-Za-z_][A-Za-z0-9_]*$")) then "\($p).\($k)" else "\($p)[\($k | tojson)]" end;

  # JSON types of a value; integral numbers are also "integer".
  def types:
    if type == "number" then (if . == floor then ["number", "integer"] else ["number"] end)
    else [type] end;

  def short: tojson | if length > 60 then .[:57] + "..." else . end;

  # Emit violations for the value at "." against schema $s at path $p.
  def check($s; $p):
    . as $v
    | ( if $s | has("type") then
          ($s.type | if type == "array" then . else [.] end) as $want
          | if any(($v | types)[]; . as $t | any($want[]; . == $t)) then empty
            else "\($p): expected \($want | join(" or ")), got \($v | type)" end
        else empty end ),
      ( if ($s | has("const")) and $v != $s.const then
          "\($p): must be \($s.const | tojson), got \($v | short)" else empty end ),
      ( if ($s | has("enum")) and (any($s.enum[]; . == $v) | not) then
          "\($p): \($v | short) is not one of \($s.enum | map(tojson) | join(", "))" else empty end ),
      ( if ($s | has("minimum")) and ($v | type) == "number" and $v < $s.minimum then
          "\($p): \($v) is less than the minimum \($s.minimum)" else empty end ),
      ( if ($v | type) == "object" then
          ( ($s.required // [])[] | select(. as $k | $v | has($k) | not)
            | "\($p): missing required key \(tojson)" ),
          ( if $s.additionalProperties == false then
              $v | keys_unsorted[] | select(. as $k | ($s.properties // {}) | has($k) | not)
              | "\($p): unexpected key \(tojson)"
            else empty end ),
          ( ($s.properties // {}) | to_entries[] | select(.key as $k | $v | has($k))
            | . as $e | $v[$e.key] | check($e.value; path_join($p; $e.key)) )
        else empty end ),
      ( if ($v | type) == "array" and ($s | has("items")) then
          range(0; $v | length) as $i | $v[$i] | check($s.items; "\($p)[\($i)]")
        else empty end );

  check($schema; "$")
'

# shellcheck disable=SC2016
unsupported='
  def supported: ["$schema", "$id", "title", "description", "type", "const", "enum",
    "required", "properties", "additionalProperties", "items", "minimum"];
  def walk_schema($p):
    (keys - supported | .[] | "\($p): unsupported schema keyword \(tojson) is not checked"),
    ((.properties // {}) | to_entries[] | .key as $k | .value | walk_schema("\($p).properties.\($k)")),
    (if has("items") then .items | walk_schema("\($p).items") else empty end);
  walk_schema("#")
'
jq -r "$unsupported" "$schema" >&2

violations=$(jq -r --slurpfile schema_doc "$schema" \
  "\$schema_doc[0] as \$schema | $validator" "$findings")

if [[ -n $violations ]]; then
  printf '%s\n' "$violations"
  exit 1
fi
