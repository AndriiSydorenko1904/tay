# Tay Core

`tay_core` is the durable single-node job engine and Protocol v1 service layer.
It includes the Unix-socket executor transport and has no HTTP or Phoenix dependency.

Choose one package according to the highest layer you need:

```elixir
{:tay_core, "~> 1.6"}  # core and Unix socket
{:tay_http, "~> 1.6"}  # HTTP(S), plus tay_core transitively
{:tay, "~> 1.6"}       # dashboard, plus tay_http and tay_core transitively
```

Repository documentation: https://github.com/AndriiSydorenko1904/tay
