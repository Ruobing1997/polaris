#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#

set -euo pipefail

usage() {
  printf '%s\n' \
    'Usage: POLARIS_PERSONAL_MACHINE=1 bash verify-part1.sh build PATH_TO_PART1_CHECKOUT' \
    '       POLARIS_PERSONAL_MACHINE=1 POLARIS_SOURCE_SERVER=1 bash verify-part1.sh api PATH_TO_PART1_CHECKOUT' \
    '' \
    'Run only on a personal computer. The build mode runs Gradle checks and may format source files.' \
    'The api mode requires a locally running Polaris server built from the Part 1 checkout' \
    'and a local RustFS server at port 9000. It creates and retains a new lab catalog.'
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

mode="${1:-}"
checkout_arg="${2:-}"
if [[ "$mode" != build && "$mode" != api ]] || [[ -z "$checkout_arg" ]]; then
  usage >&2
  exit 2
fi

[[ "${POLARIS_PERSONAL_MACHINE:-}" == 1 ]] ||
  fail 'Set POLARIS_PERSONAL_MACHINE=1 only when running on your personal computer.'

require_command git
checkout="$(git -C "$checkout_arg" rev-parse --show-toplevel)" ||
  fail "Not a Git checkout: $checkout_arg"
[[ -f "$checkout/gradlew" ]] || fail "Not a Polaris checkout: $checkout"

branch="$(git -C "$checkout" branch --show-current)"
[[ "$branch" == generic-table-location-validation-part1 ||
  "$branch" == generic-table-location-validation ]] ||
  fail "Expected a Generic Table Part 1 branch, found: ${branch:-detached HEAD}"
origin="$(git -C "$checkout" remote get-url origin)"
[[ "$origin" == *Ruobing1997/polaris* ]] ||
  fail "Expected the personal Polaris fork as origin, found: $origin"

printf 'Checkout: %s\n' "$checkout"
printf 'HEAD: %s\n' "$(git -C "$checkout" rev-parse HEAD)"
printf 'Origin: %s\n' "$origin"

if [[ "$mode" == build ]]; then
  require_command docker
  require_command tee
  [[ -z "$(git -C "$checkout" status --porcelain)" ]] ||
    fail 'The checkout is not clean. Review or save your changes before running format.'

  if [[ -n "${JAVA_HOME:-}" ]]; then
    javac_command="$JAVA_HOME/bin/javac"
  else
    javac_command="$(command -v javac || true)"
  fi
  [[ -n "$javac_command" && -x "$javac_command" ]] || fail 'JDK 21 or later javac is required.'
  javac_version="$("$javac_command" -version 2>&1)"
  [[ "$javac_version" =~ ^javac[[:space:]]+([0-9]+)([.]|$) ]] ||
    fail "Could not determine JDK version: $javac_version"
  (( BASH_REMATCH[1] >= 21 )) ||
    fail "Expected JDK 21 or later, found: $javac_version"
  docker info >/dev/null 2>&1 || fail 'Docker is not running.'

  export GRADLE_USER_HOME="${POLARIS_GRADLE_USER_HOME:-$HOME/.gradle-polaris-oss}"
  printf 'JDK: %s\n' "$javac_version"
  printf 'Gradle user home: %s\n' "$GRADLE_USER_HOME"
  log_dir="$(mktemp -d "${TMPDIR:-/tmp}/polaris-part1-build.XXXXXX")"
  printf 'Build logs: %s\n' "$log_dir"
  cd "$checkout"

  run_step() {
    local name="$1"
    shift
    printf '\n== %s ==\n' "$name"
    "$@" 2>&1 | tee "$log_dir/$name.log"
  }

  run_step targeted-tests ./gradlew :polaris-runtime-service:test \
    --tests org.apache.polaris.service.catalog.generic.PolarisGenericTableCatalogRelationalTest \
    --tests org.apache.polaris.service.catalog.generic.PolarisGenericTableCatalogNoSqlInMemTest \
    --tests org.apache.polaris.service.catalog.generic.GenericTableAllowedLocationTest
  run_step format-compile ./gradlew format compileAll
  run_step module-check ./gradlew :polaris-runtime-service:check
  git diff HEAD --check

  printf '\nAll requested Gradle checks passed. Review any files changed by format:\n'
  git status --short
  git diff HEAD --stat
  printf 'Logs: %s\n' "$log_dir"
  exit 0
fi

[[ "${POLARIS_SOURCE_SERVER:-}" == 1 ]] ||
  fail 'Start Polaris from this checkout, then set POLARIS_SOURCE_SERVER=1.'
require_command curl
require_command jq

base_url="${POLARIS_LAB_URL:-http://127.0.0.1:8181}"
[[ "$base_url" =~ ^http://(127\.0\.0\.1|localhost):[0-9]+$ ]] ||
  fail 'POLARIS_LAB_URL must be an http://localhost or http://127.0.0.1 URL with a port.'

result_dir="$(mktemp -d "${TMPDIR:-/tmp}/polaris-part1-api.XXXXXX")"
printf 'API responses: %s\n' "$result_dir"
printf 'Target server: %s (confirm this is ./gradlew run, not apache/polaris:latest)\n' "$base_url"

client_id="${POLARIS_LAB_CLIENT_ID:-root}"
client_secret="${POLARIS_LAB_CLIENT_SECRET:-s3cr3t}"
token_response="$(curl -fsS -X POST "$base_url/api/catalog/v1/oauth/tokens" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode 'grant_type=client_credentials' \
  --data-urlencode "client_id=$client_id" \
  --data-urlencode "client_secret=$client_secret" \
  --data-urlencode 'scope=PRINCIPAL_ROLE:ALL')" || fail 'Could not obtain a local lab token.'
token="$(jq -r '.access_token // empty' <<< "$token_response")"
[[ -n "$token" ]] || fail 'Token response did not contain access_token.'

headers=(-H "Authorization: Bearer $token" -H 'Polaris-Realm: POLARIS' -H 'Content-Type: application/json')
catalog="gt_p1_verify_$(date +%s)_$RANDOM"
namespace=gt_lab
catalog_api="$base_url/api/catalog/v1/$catalog"
generic_api="$base_url/api/catalog/polaris/v1/$catalog/namespaces/$namespace/generic-tables"

request_status() {
  local label="$1" method="$2" url="$3" body="${4:-}"
  local output="$result_dir/$label.json"
  if [[ "$method" == GET ]]; then
    curl -sS -o "$output" -w '%{http_code}' -X GET "$url" "${headers[@]}"
  else
    curl -sS -o "$output" -w '%{http_code}' -X "$method" "$url" \
      "${headers[@]}" --data "$body"
  fi
}

expect_status() {
  local label="$1" actual="$2" expected="$3"
  if [[ "$actual" != "$expected" ]]; then
    fail "$label: expected HTTP $expected, got $actual; response: $result_dir/$label.json"
  fi
  printf '%s: HTTP %s\n' "$label" "$actual"
}

catalog_payload="$(jq -n --arg name "$catalog" '{
  catalog: {
    name: $name,
    type: "INTERNAL",
    readOnly: false,
    properties: {"default-base-location": "s3://bucket123"},
    storageConfigInfo: {
      storageType: "S3",
      allowedLocations: ["s3://bucket123"],
      endpoint: "http://localhost:9000",
      endpointInternal: "http://localhost:9000",
      pathStyleAccess: true,
      region: "us-west-2"
    }
  }
}')"
status="$(request_status catalog-create POST "$base_url/api/management/v1/catalogs" "$catalog_payload")"
expect_status catalog-create "$status" 201

namespace_payload="$(jq -n --arg ns "$namespace" '{namespace: [$ns], properties: {}}')"
status="$(request_status namespace-create POST "$catalog_api/namespaces" "$namespace_payload")"
expect_status namespace-create "$status" 200
status="$(request_status namespace-get GET "$catalog_api/namespaces/$namespace")"
expect_status namespace-get "$status" 200
jq -e --arg location "s3://bucket123/$namespace/" \
  '.properties.location == $location' "$result_dir/namespace-get.json" >/dev/null ||
  fail "Unexpected namespace location; inspect $result_dir/namespace-get.json"

run_case() {
  local label="$1" name="$2" location="$3" expected_post="$4" expected_get="$5"
  local body post_status get_status
  if [[ "$location" == __OMIT__ ]]; then
    body="$(jq -n --arg name "$name" '{name: $name, format: "delta", properties: {}}')"
  else
    body="$(jq -n --arg name "$name" --arg location "$location" \
      '{name: $name, format: "delta", "base-location": $location, properties: {}}')"
  fi
  post_status="$(request_status "$label-post" POST "$generic_api" "$body")"
  expect_status "$label-post" "$post_status" "$expected_post"
  get_status="$(request_status "$label-get" GET "$generic_api/$name")"
  expect_status "$label-get" "$get_status" "$expected_get"
  if [[ "$expected_get" == 200 ]]; then
    if [[ "$location" == __OMIT__ ]]; then
      jq -e '.table["base-location"] == null' "$result_dir/$label-get.json" >/dev/null ||
        fail "$label: expected a null base-location"
    elif [[ "$expected_post" == 200 ]]; then
      jq -e --arg location "$location" \
        '.table["base-location"] == $location' "$result_dir/$label-get.json" >/dev/null ||
        fail "$label: unexpected base-location"
    fi
  fi
}

run_case valid valid "s3://bucket123/$namespace/valid" 200 200
run_case outside-allowed outside_allowed "s3://other-bucket/$namespace/outside_allowed" 403 404
run_case outside-namespace outside_namespace 's3://bucket123/elsewhere/outside_namespace' 403 404
run_case file-location file_location 'file:///tmp/polaris-part1-disallowed' 403 404
run_case no-location no_location __OMIT__ 200 200
run_case empty-location empty_location '' 200 200
run_case duplicate valid 's3://other-bucket/duplicate' 409 200
jq -e --arg location "s3://bucket123/$namespace/valid" \
  '.table["base-location"] == $location' "$result_dir/duplicate-get.json" >/dev/null ||
  fail 'The duplicate request changed the original table location.'

printf '\nAPI checks passed. Lab catalog %s and successful test records were retained.\n' "$catalog"
printf 'Responses: %s\n' "$result_dir"
