defmodule Tay.GRPC.Endpoint do
  @moduledoc false
  use GRPC.Endpoint

  run(Tay.GRPC.Service)
end
