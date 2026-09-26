defmodule Tay.Grpc.V1.EnqueueRequest do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:task, 1, type: :string)
  field(:args_json, 2, type: :bytes)
  field(:options_json, 3, type: :bytes)
end

defmodule Tay.Grpc.V1.JobRequest do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:job_id, 1, type: :string)
end

defmodule Tay.Grpc.V1.OperationReply do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field(:json, 1, type: :bytes)
end

defmodule Tay.Grpc.V1.Tay.Service do
  @moduledoc false
  use GRPC.Service, name: "tay.grpc.v1.Tay"

  rpc(:Enqueue, Tay.Grpc.V1.EnqueueRequest, Tay.Grpc.V1.OperationReply)
  rpc(:GetJob, Tay.Grpc.V1.JobRequest, Tay.Grpc.V1.OperationReply)
  rpc(:Cancel, Tay.Grpc.V1.JobRequest, Tay.Grpc.V1.OperationReply)
  rpc(:GetResult, Tay.Grpc.V1.JobRequest, Tay.Grpc.V1.OperationReply)
end
