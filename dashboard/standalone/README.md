# Tay Dashboard standalone host

This private Mix project assembles the published dashboard-enabled OCI release.
It is not a third Hex package. Its dependencies keep the intended boundaries:

- `tay_standalone` owns and starts the single Tay Engine and executor socket;
- `tay_dashboard` supplies the reusable LiveViews and router macro;
- this host supplies Bandit, Phoenix Endpoint, optional HTTP Basic
  authentication, and runtime HTTP configuration.

Build and test it from this directory:

```sh
mix deps.get --check-locked
mix test --warnings-as-errors
MIX_ENV=prod mix release tay_dashboard_standalone
```

Normal users should follow `../guides/docker.md` and run the OCI image rather
than invoke this release directly.
