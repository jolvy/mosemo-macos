#!/bin/sh
set -eu

if [ "$#" -ne 0 ]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 64
fi

script_directory=$(CDPATH= cd "$(dirname "$0")" && pwd)
component_root=$(CDPATH= cd "$script_directory/.." && pwd)
server_snapshot=${MOSEMO_SERVER_OPENAPI_SNAPSHOT:-}
if [ -n "$server_snapshot" ]; then
    source_contract=$server_snapshot
    server_contract=$server_snapshot
else
    source_contract="$component_root/../openapi.json"
    server_contract="$component_root/../mosemo-server/openapi/openapi.json"
fi
generator_input="$component_root/Sources/MosemoAPI/openapi.json"
generated_sources="$component_root/Sources/MosemoAPI/GeneratedSources"
developer_directory=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

if [ ! -f "$source_contract" ]; then
    printf 'OpenAPI contract not found: %s\n' "$source_contract" >&2
    exit 66
fi

if [ ! -f "$server_contract" ]; then
    printf 'Server OpenAPI snapshot not found: %s\n' "$server_contract" >&2
    exit 66
fi

if ! cmp -s "$source_contract" "$server_contract"; then
    printf 'OpenAPI contract differs from the server snapshot: %s\n' "$source_contract" >&2
    exit 65
fi

if [ -e "$generator_input" ] || [ -L "$generator_input" ]; then
    printf 'Remove the local OpenAPI input before generation: %s\n' "$generator_input" >&2
    exit 73
fi

if [ ! -d "$developer_directory" ]; then
    printf 'Xcode developer directory not found: %s\n' "$developer_directory" >&2
    exit 69
fi

if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is required to validate the OpenAPI artifact.\n' >&2
    exit 69
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/mosemo-openapi.XXXXXX")
previous_generated_sources="$temporary_directory/previous-generated-sources"
input_installed=0
generation_started=0
had_previous_generation=0
succeeded=0

cleanup() {
    if [ "$input_installed" -eq 1 ]; then
        rm -f "$generator_input"
    fi
    if [ "$generation_started" -eq 1 ] && [ "$succeeded" -eq 0 ]; then
        rm -rf "$generated_sources"
        if [ "$had_previous_generation" -eq 1 ]; then
            cp -R "$previous_generated_sources" "$generated_sources"
        fi
        printf 'Restored the previous generated sources after verification failed.\n' >&2
    fi
    rm -rf "$temporary_directory"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

jq -e '
    . as $document |
    (.openapi | type == "string" and startswith("3.1.")) and
    (.paths["/api/v1/auth/token"].post.operationId
        == "authExchangeToken") and
    (.paths["/api/v1/auth/token"].post.responses["200"] != null) and
    (.paths["/api/v1/auth/token"].post.responses["400"] != null) and
    (.paths["/api/v1/auth/token"].post.responses["422"] != null) and
    (.paths["/api/v1/accounts/me"].get.operationId
        == "accountsGetMe") and
    (.paths["/api/v1/accounts/me"].get.responses["200"] != null) and
    (.paths["/api/v1/accounts/me"].get.responses["401"] != null) and
    (.paths["/api/v1/labels"].get.operationId == "labelsList") and
    (.paths["/api/v1/activities/label-confirmations"].post.operationId
        == "activitiesConfirmSegmentLabels") and
    (.paths["/api/v1/activities/label-confirmations"].post.requestBody.content["application/json"].schema."$ref"
        == "#/components/schemas/BatchLabelConfirmationRequest") and
    (.paths["/api/v1/activities/label-confirmations"].post.responses["200"].content["application/json"].schema."$ref"
        == "#/components/schemas/BatchLabelConfirmationResponse") and
    (.paths["/api/v1/activities/label-confirmations"].post.responses["409"] != null) and
    (.paths["/api/v1/activities/label-confirmations"].post.responses["503"].headers["Retry-After"] != null) and
    (.paths["/api/v1/labels"].get.responses["200"].content["application/json"].schema.type == "array") and
    (.paths["/api/v1/labels"].get.responses["200"].content["application/json"].schema.items."$ref"
        == "#/components/schemas/LabelResponse") and
    (.components.schemas.LabelResponse.required | index("archivedAt") != null) and
    (.components.schemas.LabelResponse.properties.archivedAt.anyOf
        | map(.type) | sort == ["null", "string"]) and
    (.paths["/api/v1/devices"].post.operationId == "devicesCreate") and
    (.paths["/api/v1/devices"].post.parameters | any(
        .name == "Idempotency-Key" and .in == "header" and
        .required == true and .schema.format == "uuid"
    )) and
    (.paths["/api/v1/devices"].post.responses["201"].content["application/json"].schema."$ref"
        == "#/components/schemas/DeviceCreateResponse") and
    (.components.schemas.DeviceCreateResponse.properties.deviceId.format == "uuid") and
    (.paths["/api/v1/devices"].post.responses["401"] != null) and
    (.paths["/api/v1/devices"].post.responses["422"] != null) and
    (.paths["/api/v1/activities"].post.operationId == "activitiesCreate") and
    (.paths["/api/v1/activities/timeline"].get.operationId == "activitiesGetTimeline") and
    (.paths["/api/v1/activities/timeline"].get.parameters | any(
        .name == "date" and .in == "query" and .required == true and .schema.format == "date"
    )) and
    (.paths["/api/v1/activities/timeline"].get.responses["200"].content["application/json"].schema.type == "array") and
    (.components.schemas.AccountResponse.required | index("timezone") != null) and
    (["ActivitySegmentResponse", "CaptureGapResponse"] | all(
        . as $schema
        | ($document.components.schemas[$schema].properties.endedAt.anyOf
            | map(.type) | sort == ["null", "string"])
    )) and
    (["201", "401", "404", "405", "409", "422", "500"]
        | all(. as $status
            | $document.paths["/api/v1/activities"].post.responses[$status] != null)) and
    (.components.schemas.CapturedText.required
        | index("originalByteLength") == null) and
    (.components.schemas.CapturedText.properties.originalByteLength.anyOf
        | map(.type) | sort == ["integer", "null"])
' "$source_contract" >/dev/null

normalized_contract="$temporary_directory/openapi.json"
jq '
    def without_null_branch:
        . as $property
        | ($property.anyOf | map(select(.type != "null")) | first) as $value
        | ($property | del(.anyOf)) + $value;
    (.components.schemas.CapturedText.properties.originalByteLength) |= (
        . as $property
        | ($property.anyOf | map(select(.type == "integer")) | first) as $integer
        | ($property | del(.anyOf)) + $integer
    ) |
    (.components.schemas.ActivitySegmentResponse.properties.endedAt) |= without_null_branch |
    (.components.schemas.ActivitySegmentResponse.required) |= map(select(. != "endedAt")) |
    (.components.schemas.CaptureGapResponse.properties.endedAt) |= without_null_branch |
    (.components.schemas.CaptureGapResponse.required) |= map(select(. != "endedAt")) |
    (.paths["/api/v1/activities/label-timeline"].get.parameters[]
        | select(.name == "date" and .in == "query") | .schema) |= (
        . as $schema
        | ($schema.anyOf | map(select(.type == "string" and .format == "date")) | first) as $date
        | ($schema | del(.anyOf)) + $date
    ) |
    (.components.schemas.ActivityGroupResponse.properties.selection,
     .components.schemas.ConfirmedActivityLabelStateResponse.properties.proposal,
     .components.schemas.OpaqueActivityResponse.properties.endedAt,
     .components.schemas.LabelTimelineCaptureGapResponse.properties.endedAt,
     .components.schemas.LabelResponse.properties.archivedAt) |= (
        . as $schema
        | ($schema.anyOf | map(select(.type != "null")) | first) as $value
        | ($schema | del(.anyOf)) + $value
    ) |
    (.components.schemas.InProgressActivityResponse.required,
     .components.schemas.OpaqueActivityResponse.required,
     .components.schemas.LabelTimelineCaptureGapResponse.required) |= map(select(. != "endedAt")) |
    .components.schemas.LabelResponse.required |= map(select(. != "archivedAt")) |
    .components.schemas.InProgressActivityResponse.properties.endedAt |= (
        . + {"type": "string", "format": "date-time"}
    )
' "$source_contract" > "$normalized_contract"

if [ -d "$generated_sources" ]; then
    cp -R "$generated_sources" "$previous_generated_sources"
    had_previous_generation=1
fi
generation_started=1

input_installed=1
ln -s "$normalized_contract" "$generator_input"

(
    cd "$component_root"
    DEVELOPER_DIR="$developer_directory" xcrun swift package \
        --allow-writing-to-package-directory \
        generate-code-from-openapi \
        --target MosemoAPI
    DEVELOPER_DIR="$developer_directory" xcrun swift build --target MosemoAPI
    DEVELOPER_DIR="$developer_directory" xcrun swift test
)

succeeded=1
printf 'Generated and verified the client from %s\n' "$source_contract"
