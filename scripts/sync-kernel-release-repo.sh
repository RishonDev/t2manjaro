#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$ROOT_DIR/.github/release-sync-config.json}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "Missing required tool: $1" >&2
        exit 1
    fi
}

require_tool gh
require_tool jq
require_tool repo-add

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
    echo "GH_TOKEN is required for release downloads and uploads." >&2
    exit 1
fi

SOURCE_REPO="$(jq -r '.source_repo' "$CONFIG_FILE")"
SOURCE_ASSET_PATTERN="$(jq -r '.source_asset_pattern' "$CONFIG_FILE")"
TARGET_REPO="$(jq -r '.target_repo' "$CONFIG_FILE")"
TARGET_RELEASE_TAG="$(jq -r '.target_release_tag' "$CONFIG_FILE")"
TARGET_REPO_DB_NAME="$(jq -r '.target_repo_db_name' "$CONFIG_FILE")"
TARGET_ASSET_CLEANUP_PATTERN="$(jq -r '.target_asset_cleanup_pattern' "$CONFIG_FILE")"
LOCAL_REPO_DIR="$WORK_DIR/repo"

mkdir -p "$LOCAL_REPO_DIR"

delete_asset_if_present() {
    local repo="$1"
    local tag="$2"
    local asset_name="$3"

    if gh release view "$tag" --repo "$repo" --json assets --jq ".assets[] | select(.name == \"$asset_name\") | .name" | grep -qx "$asset_name"; then
        gh release delete-asset "$tag" "$asset_name" --repo "$repo" -y
    fi
}

echo "Resolving source release from $SOURCE_REPO"
source_release_json="$(gh api "/repos/$SOURCE_REPO/releases/latest")"
source_tag="$(jq -r '.tag_name' <<<"$source_release_json")"

if [[ -z "$source_tag" || "$source_tag" == "null" ]]; then
    echo "Could not resolve latest release tag for $SOURCE_REPO" >&2
    exit 1
fi

mapfile -t source_assets < <(
    jq -r --arg re "$SOURCE_ASSET_PATTERN" '.assets[] | select(.name | test($re)) | .name' <<<"$source_release_json"
)

if [[ "${#source_assets[@]}" -eq 0 ]]; then
    echo "No source assets matched $SOURCE_ASSET_PATTERN in $SOURCE_REPO@$source_tag" >&2
    exit 1
fi

echo "Ensuring target release $TARGET_RELEASE_TAG exists in $TARGET_REPO"
if ! gh release view "$TARGET_RELEASE_TAG" --repo "$TARGET_REPO" >/dev/null 2>&1; then
    gh release create "$TARGET_RELEASE_TAG" --repo "$TARGET_REPO" --title "$TARGET_RELEASE_TAG" --notes "Pacman repo backing release for t2manjaro."
fi

target_assets_json="$(gh release view "$TARGET_RELEASE_TAG" --repo "$TARGET_REPO" --json assets)"

mapfile -t retained_packages < <(
    jq -r \
        --arg cleanup_re "$TARGET_ASSET_CLEANUP_PATTERN" \
        '.assets[]
        | select((.name | test("\\.pkg\\.tar\\.zst$")) and (.name | test($cleanup_re) | not))
        | .name' <<<"$target_assets_json"
)

mapfile -t replaced_assets < <(
    jq -r \
        --arg cleanup_re "$TARGET_ASSET_CLEANUP_PATTERN" \
        --arg repo_name "$TARGET_REPO_DB_NAME" \
        '.assets[]
        | select(
            (.name | test($cleanup_re))
            or (.name == ($repo_name + ".db"))
            or (.name == ($repo_name + ".db.tar.gz"))
            or (.name == ($repo_name + ".files"))
            or (.name == ($repo_name + ".files.tar.gz"))
          )
        | .name' <<<"$target_assets_json"
)

if [[ "${#retained_packages[@]}" -gt 0 ]]; then
    echo "Downloading retained package assets from target release"
    for asset in "${retained_packages[@]}"; do
        gh release download "$TARGET_RELEASE_TAG" --repo "$TARGET_REPO" --pattern "$asset" --dir "$LOCAL_REPO_DIR"
    done
fi

echo "Downloading refreshed kernel packages from source release $source_tag"
for asset in "${source_assets[@]}"; do
    gh release download "$source_tag" --repo "$SOURCE_REPO" --pattern "$asset" --dir "$LOCAL_REPO_DIR"
done

echo "Rebuilding pacman metadata"
(
    cd "$LOCAL_REPO_DIR"
    repo-add "$TARGET_REPO_DB_NAME.db.tar.gz" ./*.pkg.tar.zst
    cp -f "$TARGET_REPO_DB_NAME.db.tar.gz" "$TARGET_REPO_DB_NAME.db"
    cp -f "$TARGET_REPO_DB_NAME.files.tar.gz" "$TARGET_REPO_DB_NAME.files"
)

if [[ "${#replaced_assets[@]}" -gt 0 ]]; then
    echo "Removing replaced assets from target release"
    for asset in "${replaced_assets[@]}"; do
        delete_asset_if_present "$TARGET_REPO" "$TARGET_RELEASE_TAG" "$asset"
    done
fi

echo "Uploading refreshed assets to $TARGET_REPO@$TARGET_RELEASE_TAG"
upload_args=()
for asset in "${source_assets[@]}"; do
    upload_args+=("$LOCAL_REPO_DIR/$asset")
done
upload_args+=(
    "$LOCAL_REPO_DIR/$TARGET_REPO_DB_NAME.db"
    "$LOCAL_REPO_DIR/$TARGET_REPO_DB_NAME.db.tar.gz"
    "$LOCAL_REPO_DIR/$TARGET_REPO_DB_NAME.files"
    "$LOCAL_REPO_DIR/$TARGET_REPO_DB_NAME.files.tar.gz"
)

gh release upload "$TARGET_RELEASE_TAG" "${upload_args[@]}" --repo "$TARGET_REPO"

echo "Release-backed pacman repo sync completed"
