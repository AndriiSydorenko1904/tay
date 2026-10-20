defmodule Tay.Storage do
  @moduledoc "Explicit administrative initialization; Engine recovery itself never bootstraps."
  defdelegate initialize(options), to: Tay.Storage.Writer
end
