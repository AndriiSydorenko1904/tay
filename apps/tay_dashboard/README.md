# Tay Dashboard

`tay_dashboard` supplies the Phoenix LiveView dashboard for `tay`. It depends
on `tay` and Phoenix/LiveView, but not on Bandit, so a host Phoenix application
can mount it with `Tay.Dashboard.Router.tay_dashboard/2`.

Maintainers build or publish this umbrella child with `TAY_HEX_BUILD=1`; that
switches its local core dependency to the published `tay` version.
