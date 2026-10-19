# Releasing Tay

Tay publishes four independent public artifacts from this repository:

- `tay_core` on Hex.pm for the core Elixir engine;
- `tay_http` on Hex.pm for the Bandit transport;
- `tay` on Hex.pm for the complete Phoenix LiveView bundle;
- `tay-client` on PyPI for the Python SDK (`import tay`).

Their versions are independent. A Tay release publishes `tay-client` only when
`clients/python/` changed since the preceding Tay tag. Such a change must bump
the PEP 440 package version; an unchanged client keeps its existing version.

Published versions are immutable. Run every check below from a clean checkout
of the release tag, and publish only after the GitHub repository and tag are
public.

## Prepare

1. Set the same Tay release version in each `apps/*/mix.exs`. If `clients/python/` changed, also
   bump its independent PEP 440 version in `clients/python/pyproject.toml`.
2. Move the release notes from `Unreleased` to that version in `CHANGELOG.md`.
3. Update versioned GitHub documentation links in package metadata, the pinned
   container tags in `compose.yml` and deployment guides, and keep the README
   quick-start pull commands on the stable `latest` tag.
4. Commit and push the release commit to `main` without creating the tag yet.
5. Wait for both `Continuous integration` and `Standalone runtime` to succeed
   for that exact commit SHA.
6. Create `v<mix-version>`, push the tag, and verify that both the repository and
   tag are accessible without authentication.

## Qualify

```sh
mix format --check-formatted
mix compile --warnings-as-errors
mix dialyzer
mix test --warnings-as-errors
TAY_PACKAGE_TEST=1 MIX_ENV=test mix do --app tay_core test test/tay/system/package_test.exs --warnings-as-errors
mix tay.hex.build

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

Authenticate interactively for the first Hex release, inspect the file list,
and publish the package and HexDocs:

```sh
mix hex.user auth
mix tay.hex.publish --dry-run
mix tay.hex.publish
```

The dry run exercises the same package order and metadata switching without
uploading artifacts or requesting a two-factor code. During real publication,
the child Hex processes inherit the terminal so interactive OTP prompts work.
Adapter packages resolve their just-published upstream package inside a
disposable build workspace; the repository lockfile and dependency directory
remain unchanged. Each package and its HexDocs are published by one Hex command,
so a normal release requires one successful OTP authentication per package.

To replace HexDocs for an already published version without republishing the
immutable package tarball, publish only docs from the corresponding child:

```sh
mix tay.hex.publish docs
```

The repository tasks publish in dependency order and switch adapter package
metadata from umbrella paths to published Hex dependencies internally; no
`TAY_HEX_BUILD` environment variable is required at the command line.

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
