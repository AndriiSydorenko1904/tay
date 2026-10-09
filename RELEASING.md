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

1. Set the Tay release version in `mix.exs`. If `clients/python/` changed, also
   bump its independent PEP 440 version in `clients/python/pyproject.toml`.
2. Move the release notes from `Unreleased` to that version in `CHANGELOG.md`.
3. Update versioned GitHub documentation links in package metadata.
4. Commit, create `v<mix-version>`, and push the commit and tag.
5. Verify that `https://github.com/AndriiSydorenko1904/tay` and the tag are
   accessible without authentication.

## Qualify

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix test --warnings-as-errors
TAY_PACKAGE_TEST=1 mix test test/tay/system/package_test.exs --warnings-as-errors
mix hex.build

uvx ruff check clients/python
uvx ruff format --check clients/python
python -m unittest discover -s clients/python/tests -v
uv build clients/python
uvx twine check clients/python/dist/*
```

Install the wheel into a fresh virtual environment and verify both `import tay`
and `tay-worker --help` before uploading it.

## Publish

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
