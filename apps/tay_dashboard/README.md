# Tay Dashboard

`tay_dashboard` is the complete Tay web bundle. It supplies the Phoenix
LiveView dashboard, depends on `tay_http`, and transitively installs the core
`tay` engine and Bandit HTTP(S) transport. A host Phoenix application can mount
it with `Tay.Dashboard.Router.tay_dashboard/2`.
