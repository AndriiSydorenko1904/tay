# Releasing Tay

Tay is published as two independent public packages with the same version:

- `tay` on Hex.pm for the Elixir engine;
- `tay-client` on PyPI for the Python SDK (`import tay`).

Published versions are immutable. Run every check below from a clean checkout
of the release tag, and publish only after the GitHub repository and tag are
public.

## Prepare

1. Set the same SemVer in `mix.exs` and `clients/python/pyproject.toml`.
2. Move the release notes from `Unreleased` to that version in `CHANGELOG.md`.
3. Update versioned GitHub documentation links in both package metadata files.
4. Commit, create `v<version>`, and push the commit and tag.
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

For PyPI, prefer a Trusted Publisher attached to the GitHub release workflow.
For a manual first release, authenticate with an API token and upload only the
artifacts produced from the release tag:

```sh
uvx twine upload clients/python/dist/*
```

Never store Hex or PyPI credentials in this repository. After publishing,
create clean consumer projects and install `{:tay, "~> <version>"}` from Hex
and `tay-client==<version>` from PyPI.
