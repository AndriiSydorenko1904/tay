defmodule Tay.Storage.CRC32C.Native do
  @moduledoc false
  @on_load :load_nif
  @nifs [available?: 0, update: 2, record_checksums: 2]

  def load_nif do
    path = :filename.join(:code.priv_dir(:tay), ~c"tay_crc32c")

    :erlang.load_nif(path, 0)
  end

  # These functions must be replaced by the C NIF. A load error prevents this
  # module from loading; the historical Elixir implementation is never used.
  def available?, do: :erlang.nif_error(:not_loaded)
  def update(_register, _bytes), do: :erlang.nif_error(:not_loaded)
  def record_checksums(_header, _payload), do: :erlang.nif_error(:not_loaded)
end
