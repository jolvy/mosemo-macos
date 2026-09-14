#!/bin/sh
set -eu

if [ "$#" -ne 0 ]; then
    printf 'Usage: %s\n' "$0" >&2
    exit 64
fi

script_directory=$(CDPATH= cd "$(dirname "$0")" && pwd)
component_root=$(CDPATH= cd "$script_directory/.." && pwd)
source_contract="$component_root/../mosemo-server/openapi/openapi.json"
generator_input="$component_root/Sources/MosemoAPI/openapi.json"
generated_sources="$component_root/Sources/MosemoAPI/GeneratedSources"
developer_directory=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

if [ ! -f "$source_contract" ]; then
    printf 'Server OpenAPI contract not found: %s\n' "$source_contract" >&2
    exit 66
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
    (.openapi | type == "string" and startswith("3.1.")) and
    (.paths["/api/v1/auth/token"].post.operationId
        == "authExchangeToken") and
    (.paths["/api/v1/auth/token"].post.responses["200"] != null) and
    (.paths["/api/v1/auth/token"].post.responses["400"] != null) and
    (.paths["/api/v1/auth/token"].post.responses["422"] != null) and
    (.paths["/api/v1/accounts/me"].get.operationId
        == "accountsGetMe") and
    (.paths["/api/v1/accounts/me"].get.responses["200"] != null) and
    (.paths["/api/v1/accounts/me"].get.responses["401"] != null)
' "$source_contract" >/dev/null

if [ -d "$generated_sources" ]; then
    cp -R "$generated_sources" "$previous_generated_sources"
    had_previous_generation=1
fi
generation_started=1

input_installed=1
ln -s ../../../mosemo-server/openapi/openapi.json "$generator_input"

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
