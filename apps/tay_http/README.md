# Tay HTTP

`tay_http` supplies the Bandit HTTP transport for `tay`. It depends on `tay`,
while the core package remains independent from Bandit and Phoenix.

Existing `http_port`, `http_ip`, and TLS engine options remain supported when
this package is installed.

Maintainers build or publish this umbrella child with `TAY_HEX_BUILD=1`; that
switches its local core dependency to the published `tay` version.
