# Releasing Tay

Tay publishes two independent public packages from this repository:

- `tay` on Hex.pm for the Elixir engine and Phoenix LiveView dashboard;
- `tay-client` on PyPI for the Python SDK (`import tay`).

Their versions are independent. A Tay release publishes `tay-client` only when
`clients/python/` changed since the preceding Tay tag. Such a change must bump
the PEP 440 package version; an unchanged client keeps its existing version.

Published versions are immutable. Run every check below from a clean checkout
of the release tag, and publish only after the GitHub repository and tag are
public.

## Prepare

Before promoting the 1.8 release candidate, complete the operational smoke run and
the previous-stable-version upgrade/cold-restore drill described in
[`bench/README.md`](bench/README.md). Retain the final reports, including failed
attempts. Extended soaks are optional and do not impose a 24-hour release wait.
An interrupted run remains partial evidence, not a completed soak. The smoke
run does not replace the required CI and Standalone checks for the release commit.

The prepared 1.8.1 checkout uses engine/container version `1.8.1` and Python
package `1.4.4`. Include SDK README and comment-only changes when detecting a
changed client. Keep historical rc
changelog entries and format-introduction versions intact. Mark GitHub release
candidates as prereleases; promote only the final stable tag after the checks
below. Preparing local files does not publish Hex, PyPI, or containers.

1. Set the Tay release version in `mix.exs`. If `clients/python/` changed, also
   bump its independent PEP 440 version in `clients/python/pyproject.toml`.
2. Move the release notes from `Unreleased` to that version in `CHANGELOG.md`.
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

uvx ruff check clients/python
uvx ruff format --check clients/python
uv run --with mypy --with cryptography mypy clients/python/tay
python -m unittest discover -s clients/python/tests -v
uv build clients/python
uvx twine check clients/python/dist/*
```

Install the wheel into a fresh virtual environment and verify both `import tay`
and `tay-worker --help` before uploading it.

## Publish

Container and PyPI publication require successful `Continuous integration`
and `Standalone runtime` push runs for the exact release SHA. Missing or failed
checks and API errors refuse publication. Full qualification and performance
comparisons are optional.

The local `deploy-helper.sh` checks these two required workflows. For historical
tags whose embedded publication workflows still require full qualification, it
retries publication using the current workflows on `main`. Published tags and
package versions do not need to change for this publication-policy update.

Authenticate interactively for the first Hex release, inspect the file list,
and publish the package and HexDocs:

```sh
mix hex.user auth
mix hex.publish
```

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

Never store Hex or PyPI credentials in this repository. After publishing,
create clean consumer projects and install `{:tay, "~> <version>"}` from Hex
and the independently released `tay-client==<python-version>` from PyPI.

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
