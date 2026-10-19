# Tay

`tay` is the complete Tay web bundle. It supplies the Phoenix
LiveView dashboard, depends on `tay_http`, and transitively installs the core
`tay_core` engine and Bandit HTTP(S) transport. A host Phoenix application can mount
it with `Tay.Dashboard.Router.tay_dashboard/2`.

Installing the package does not start or expose an endpoint. In a host Phoenix
application, mounting `tay_dashboard/2` activates the UI and the host endpoint's
existing `secret_key_base` protects sessions, CSRF, and LiveView. The
standalone-only `TAY_ENABLE_DASHBOARD` and `TAY_DASHBOARD_SECRET_KEY_BASE`
environment variables are not needed in this deployment shape.

The standalone/container release owns a separate Phoenix endpoint. Its bundled
UI remains disabled until `TAY_ENABLE_DASHBOARD=true`, and enabling it requires
a stable `TAY_DASHBOARD_SECRET_KEY_BASE` of at least 64 random bytes.
