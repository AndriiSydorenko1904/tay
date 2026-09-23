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

Local development uses the sibling Tay checkout and `mix.lock`. Package builds
use the published Tay package and the independently committed
`mix.package.lock`. After publishing the matching Tay release, publish the
dashboard without modifying either lock file:

```sh
TAY_DASHBOARD_PACKAGE=1 mix hex.publish
```

When the minimum Tay version changes, refresh only the package lock with
`TAY_DASHBOARD_PACKAGE=1 mix deps.update tay` and commit it with the version
change.

When adding a guide, include it in both the `docs[:extras]` and package `files`
lists in `mix.exs`. Before release, verify that internal links resolve, examples
use the current package/image version, public modules have useful module docs,
and security-sensitive deployment examples do not imply public unauthenticated
exposure.
