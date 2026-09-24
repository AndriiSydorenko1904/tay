#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPOSITORY="AndriiSydorenko1904/tay"
readonly CONTAINER_WORKFLOW="publish-container.yml"
readonly PYTHON_WORKFLOW="publish-python.yml"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CORE_IMAGE="ghcr.io/andriisydorenko1904/tay"
readonly DASHBOARD_IMAGE="ghcr.io/andriisydorenko1904/tay-dashboard"
readonly PYTHON_PACKAGE="tay-client"

cd "$SCRIPT_DIR"

for command in git gh curl docker; do
  command -v "$command" >/dev/null || {
    echo "$command is required" >&2
    exit 1
  }
done

gh auth status --hostname github.com >/dev/null

publish_containers=true
publish_python=true
force_containers=false
create_release=true
tag=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --containers-only) publish_python=false ;;
    --python-only) publish_containers=false ;;
    --force | --force-containers) force_containers=true ;;
    --no-release) create_release=false ;;
    -h | --help)
      echo "Usage: $0 [--containers-only|--python-only] [--force-containers] [--no-release] [vVERSION]"
      exit 0
      ;;
    v*)
      [[ -z "$tag" ]] || { echo "Only one release tag may be supplied" >&2; exit 1; }
      tag="$1"
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

[[ "$publish_containers" == true || "$publish_python" == true ]] || {
  echo "Nothing selected for publication" >&2
  exit 1
}

if [[ "$create_release" == true &&
      ("$publish_containers" != true || "$publish_python" != true) ]]; then
  echo "A GitHub Release triggers both publication workflows." >&2
  echo "Run the full release, or add --no-release for a partial manual publication." >&2
  exit 1
fi

version=$(sed -n 's/^[[:space:]]*@version "\([^"]*\)"/\1/p' mix.exs)
dashboard_version=$(sed -n 's/^[[:space:]]*@version "\([^"]*\)"/\1/p' dashboard/mix.exs)
python_version=$(sed -n 's/^[[:space:]]*version = "\([^"]*\)"/\1/p' clients/python/pyproject.toml)

[[ -n "$version" ]] || { echo "Could not read the Tay version from mix.exs" >&2; exit 1; }
[[ "$dashboard_version" == "$version" ]] || {
  echo "Dashboard version $dashboard_version does not match Tay $version" >&2
  exit 1
}
[[ "$python_version" == "$version" ]] || {
  echo "Python client version $python_version does not match Tay $version" >&2
  exit 1
}

tag="${tag:-v$version}"
[[ "$tag" == "v$version" ]] || {
  echo "Tag $tag does not match package version $version (expected v$version)" >&2
  exit 1
}

git rev-parse --verify --quiet "refs/tags/$tag" >/dev/null || {
  echo "Local Git tag $tag does not exist" >&2
  exit 1
}

git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null || {
  echo "Git tag $tag has not been pushed to origin" >&2
  exit 1
}

readonly TAG_COMMIT="$(git rev-list -n 1 "$tag")"
release_created=false

ensure_release() {
  if gh release view "$tag" --repo "$REPOSITORY" >/dev/null 2>&1; then
    echo "GitHub Release $tag already exists; keeping it."
    return
  fi

  echo "Creating GitHub Release $tag..."
  gh release create "$tag" \
    --repo "$REPOSITORY" \
    --verify-tag \
    --title "Tay $version" \
    --generate-notes
  release_created=true
}

release_run() {
  gh run list --repo "$REPOSITORY" --workflow "$1" --event release --limit 20 \
    --json databaseId,headSha \
    --jq ".[] | select(.headSha == \"$TAG_COMMIT\") | .databaseId" \
    | head -n 1
}

watch_release_workflow() {
  workflow="$1"
  label="$2"
  run_id=""

  for _ in {1..30}; do
    run_id=$(release_run "$workflow")
    [[ -n "$run_id" ]] && break
    sleep 2
  done

  [[ -n "$run_id" ]] || {
    echo "Release $tag was created, but the $label workflow did not appear after 60 seconds" >&2
    exit 1
  }

  echo "Watching $label release workflow run $run_id..."
  gh run watch "$run_id" --repo "$REPOSITORY" --exit-status
}

images_are_published() {
  docker buildx imagetools inspect "$CORE_IMAGE:$version" >/dev/null 2>&1 &&
    docker buildx imagetools inspect "$DASHBOARD_IMAGE:$version" >/dev/null 2>&1
}

python_is_published() {
  curl --fail --silent --show-error --output /dev/null "https://pypi.org/pypi/$PYTHON_PACKAGE/$version/json"
}

active_run() {
  gh run list --repo "$REPOSITORY" --workflow "$1" --limit 20 \
    --json databaseId,status \
    --jq '[.[] | select(.status != "completed")][0].databaseId // empty'
}

dispatch_and_watch() {
  workflow="$1"
  label="$2"
  known_runs=$(mktemp)

  gh run list --repo "$REPOSITORY" --workflow "$workflow" --event workflow_dispatch \
    --limit 50 --json databaseId --jq '.[].databaseId' >"$known_runs"

  echo "Starting $label publication for $tag..."
  gh workflow run "$workflow" --repo "$REPOSITORY" --ref main -f "tag=$tag"

  run_id=""
  for _ in {1..30}; do
    while IFS= read -r candidate; do
      if ! grep -Fxq "$candidate" "$known_runs"; then
        run_id="$candidate"
        break
      fi
    done < <(
      gh run list --repo "$REPOSITORY" --workflow "$workflow" --event workflow_dispatch \
        --limit 20 --json databaseId --jq '.[].databaseId'
    )

    [[ -n "$run_id" ]] && break
    sleep 2
  done

  rm -f "$known_runs"

  [[ -n "$run_id" ]] || {
    echo "GitHub accepted $label dispatch, but no run appeared after 60 seconds" >&2
    exit 1
  }

  echo "Watching $label workflow run $run_id..."
  gh run watch "$run_id" --repo "$REPOSITORY" --exit-status
}

publish_container_images() {
  if [[ "$force_containers" == false ]] && images_are_published; then
    echo "Containers for $tag are already published; skipping them."
    return
  fi

  if [[ "$force_containers" == false ]]; then
    run_id=$(active_run "$CONTAINER_WORKFLOW")
    if [[ -n "$run_id" ]]; then
      echo "Container publication run $run_id is active; waiting for it..."
      gh run watch "$run_id" --repo "$REPOSITORY" --exit-status || true
      images_are_published && return
    fi
  fi

  dispatch_and_watch "$CONTAINER_WORKFLOW" "container"
}

publish_python_client() {
  if python_is_published; then
    echo "$PYTHON_PACKAGE $version is already on PyPI; skipping it."
    return
  fi

  run_id=$(active_run "$PYTHON_WORKFLOW")
  if [[ -n "$run_id" ]]; then
    echo "Python publication run $run_id is active; waiting for it..."
    gh run watch "$run_id" --repo "$REPOSITORY" --exit-status || true
    python_is_published && return
  fi

  dispatch_and_watch "$PYTHON_WORKFLOW" "Python client"
}

if [[ "$create_release" == true ]]; then
  ensure_release
fi

if [[ "$release_created" == true ]]; then
  watch_release_workflow "$CONTAINER_WORKFLOW" "container"
  watch_release_workflow "$PYTHON_WORKFLOW" "Python client"
else
  [[ "$publish_containers" == true ]] && publish_container_images
  [[ "$publish_python" == true ]] && publish_python_client
fi

echo "Publication complete for $tag:"
[[ "$publish_containers" == true ]] && {
  echo "  $CORE_IMAGE:$version"
  echo "  $DASHBOARD_IMAGE:$version"
  echo "  $CORE_IMAGE:latest"
  echo "  $DASHBOARD_IMAGE:latest"
}
[[ "$publish_python" == true ]] && echo "  https://pypi.org/project/$PYTHON_PACKAGE/$version/"
