# Documentation development

Dashboard documentation has two distinct layers:

- Maintained sources: `README.md`, `guides/*.md`, and `@moduledoc` / `@doc`
  content under `lib/`.
- Generated output: the `doc/` directory produced by ExDoc.

`dashboard/.gitignore` intentionally excludes `/doc/`. Generated HTML, search
indexes, fonts, JavaScript, Markdown exports, and EPUB files are derived build
artifacts. Committing them would duplicate the sources and create noisy diffs
on every ExDoc update. The published HexDocs site is generated from the package
sources during release publication.

From `dashboard/`, validate and build the documentation with:

```sh
mix deps.get --check-locked
mix docs
```

Open `doc/index.html` locally. Deleting `doc/` loses no authored content; the
directory can always be regenerated.

## Publishing

These are separate dependency graphs, even though the packages live in one
repository:

- `dashboard/mix.lock` is for local dashboard development, where Tay is the
  sibling path dependency.
- `dashboard/standalone/mix.lock` is for the standalone host, which combines
  Tay, the dashboard, and Bandit in one release.
- `dashboard/mix.package.lock` is for publishing the dashboard, where Tay is a
  published Hex dependency instead of a path dependency.

The package lock may lag behind a new source release until that Tay version is
published to Hex. In particular, do not publish the dashboard while its package
lock still points to an older Tay version. After publishing the matching Tay
release, refresh the package lock and publish the dashboard:

```sh
TAY_DASHBOARD_PACKAGE=1 mix deps.update tay
TAY_DASHBOARD_PACKAGE=1 mix deps.get --check-locked
TAY_DASHBOARD_PACKAGE=1 mix hex.publish
```

Commit the refreshed `mix.package.lock` separately once the matching Tay
release is available on Hex. Local and standalone locks do not need to change
for that publication step.

When adding a guide, include it in both the `docs[:extras]` and package `files`
lists in `mix.exs`. Before release, verify that internal links resolve, examples
use the current package/image version, public modules have useful module docs,
and security-sensitive deployment examples do not imply public unauthenticated
exposure.
