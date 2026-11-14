# Releasing Tay

Tay publishes three independently versioned public packages from this repository:

- `tay` on Hex.pm for the Elixir engine and Phoenix LiveView dashboard;
- `tay-client` on PyPI for the Python SDK (`import tay`);
- `tay-client` on npm for the Node.js SDK (Node.js 22+, ESM and CommonJS).

A Tay GitHub release triggers container and Python publication. The Python
workflow publishes only when `clients/python/` changed since the preceding Tay
tag. Such a change must bump its PEP 440 package version, including SDK README
or comment-only changes. Node.js releases use their own npm package version and
are published manually.

| Artifact | Version source | Publication |
| --- | --- | --- |
| Hex package and HexDocs | `mix.exs` | `mix hex.publish` |
| GHCR container | `mix.exs` | `publish-container.yml`, through release or manual dispatch |
| Python SDK | `clients/python/pyproject.toml` | `publish-python.yml`, through release or manual dispatch |
| Node.js SDK | `clients/node/package.json` | `npm publish` from `clients/node` |

Published package versions are immutable. Prepare changes in a clean checkout,
qualify the release commit, and publish artifacts from its public tag.

## Prepare

Select new versions for the artifacts being changed. Keep historical changelog
entries and format-introduction versions intact. Mark GitHub release candidates
as prereleases. Storage and recovery changes can be exercised with the
operational smoke and previous-version upgrade/cold-restore drill in
[`bench/README.md`](bench/README.md). Retain reports, including failed attempts.

1. Set the Tay release version in `mix.exs`. If `clients/python/` changed, also
   bump its independent PEP 440 version in `clients/python/pyproject.toml`.
   For a Node.js SDK release, update `clients/node/package.json` and its lockfile
   together, for example with `npm version patch --no-git-tag-version` from
   `clients/node`.
2. Add the versioned release notes to `CHANGELOG.md`, moving any corresponding
   `Unreleased` notes into that entry.
3. Update versioned HexDocs links in the README and package metadata, versioned
   GitHub documentation links, the pinned
   container tags in `compose.yml` and deployment guides, and keep the README
   quick-start pull commands on the stable `latest` tag.
4. Commit and push the release commit to `main` without creating the tag yet.
5. Wait for both `Continuous integration` and `Standalone runtime` to succeed
   for that exact commit SHA.
6. Full qualification and performance comparisons are optional. Run them
   explicitly when needed; they do not block publication after CI and
   Standalone runtime pass for the release commit.
7. Create `v<mix-version>`, push the tag, and verify that both the repository and
   tag are accessible without authentication.

## Qualify

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix dialyzer
mix test --warnings-as-errors
TAY_PACKAGE_TEST=1 mix test test/tay/system/package_test.exs --warnings-as-errors
mix hex.build

uv run --with ruff ruff check clients/python
uv run --with ruff ruff format --check clients/python
uv run --with mypy --with cryptography mypy clients/python/tay
uv run --with pytest pytest clients/python
uv build clients/python
uv run --with twine twine check clients/python/dist/*

(cd clients/node && npm ci && npm run check && npm test && npm run pack:check)
```

Install the wheel into a fresh virtual environment and verify both `import tay`
and `tay-worker --help` before uploading it.

Run Node.js checks with Node.js 22 or later. CI tests the SDK on Node.js 22,
24 and 26 and Python on 3.11–3.14. For compaction-only iteration, use the
[reusable cold-store fixtures](bench/README.md#reusable-compaction-fixtures).
The fixture harness reports restore, startup, delta setup and compaction
separately. Extended qualification, performance comparisons and soaks are
optional. Preserve interrupted runs as partial evidence.

## Publish

Container and PyPI publication require successful `Continuous integration`
and `Standalone runtime` push runs for the exact release SHA. Missing or failed
checks and API errors refuse publication. Full qualification and performance
comparisons are optional.

The local `deploy-helper.sh` requires a clean working tree and matching local
and remote release tags, with the tagged commit contained in `origin/main`.
It checks CI and Standalone for that exact SHA, waiting for running checks and
refusing failed checks. Push the release commit to `main` before invoking it.

After the two required workflows succeed, create and push the release tag.
The shell variable below reads the version already prepared in `mix.exs`.

```sh
release_version=$(sed -n 's/^[[:space:]]*@version "\([^"]*\)"/\1/p' mix.exs)
git tag "v$release_version"
git push origin "refs/tags/v$release_version"
```

Authenticate to Hex when needed, inspect the file list, and publish the package
and HexDocs from the tagged checkout. Hex may request an OTP code.

```sh
mix hex.user auth
mix hex.publish
```

Run the helper for the same tag to publish containers and the changed Python SDK.

```sh
./deploy-helper.sh "v$release_version"
```

The helper creates a GitHub Release when it is missing, preserves an existing
release, and dispatches the publication workflows from `main` with the release
tag as input. It skips an existing container version and an already published
Python version. Existing release notes can be updated explicitly with
`gh release edit`. Hex and npm publication are separate steps.

For a container-only retry of an existing release, use
`./deploy-helper.sh --containers-only --no-release "v$release_version"`.
`--force-containers` rebuilds an existing container version when explicitly
requested. Inspect the helper output and workflow conclusions after a retry.

## Python SDK setup

Publish `tay-client` through the `publish-python.yml` GitHub Actions workflow
and PyPI Trusted Publishing. For the first release, configure a pending GitHub
publisher in the PyPI account with these exact values:

- PyPI project name: `tay-client`
- GitHub owner: `AndriiSydorenko1904`
- GitHub repository: `tay`
- Workflow filename: `publish-python.yml`
- Environment name: `pypi`

Create the `pypi` environment in the GitHub repository. Publishing a GitHub
release triggers the workflow automatically; an existing tag can instead be
published with the workflow's manual `tag` input. The workflow skips an
unchanged client. For a changed client it requires a version bump, qualifies
and builds the package, and uses GitHub OIDC to publish without a stored PyPI
token.

For an emergency manual release, authenticate with a scoped PyPI API token and
upload only artifacts produced from the release tag:

```sh
uvx twine upload clients/python/dist/*
```

## Node.js SDK publication

After updating the npm package version and passing the Node.js checks, publish
from the client directory. Its `prepack` script builds both ESM and CommonJS
artifacts.

```sh
cd clients/node
npm login
npm publish --dry-run
npm publish
```

The account must have publication rights and satisfy npm's authentication
requirements. Verify the published package in a fresh consumer with ESM,
CommonJS and TypeScript imports.

Never store Hex, PyPI or npm credentials in this repository. After publishing,
create clean consumer projects and install `{:tay, "~> <version>"}` from Hex
and the independently released SDK versions from PyPI and npm. Verify the GHCR
tag and its `linux/amd64` and `linux/arm64` manifests as well.

## Update documentation only

To update the rendered HexDocs pages for the version in `mix.exs`:

```sh
mix docs --warnings-as-errors
mix hex.publish docs
```

This updates documentation without replacing the Hex package or publishing
containers/Python packages. HexDocs documentation can be updated after the
package replacement window has closed.

The README shown on the Hex.pm package page is extracted from the package
archive. Updating HexDocs does not change that README. Ship its updated links
and the package's Documentation metadata with the next package release; do not
replace an immutable package version just to update its README. Use absolute
HexDocs HTML URLs in README guide links so Hex.pm does not send readers to raw
Markdown files under `repo.hex.pm/preview`.
