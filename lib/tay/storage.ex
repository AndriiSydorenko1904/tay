defmodule Tay.Storage do
  @moduledoc "Explicit administrative initialization; ordinary Engine recovery never bootstraps."
  defdelegate initialize(options), to: Tay.Storage.Writer
end
