defmodule Tay.Protocol.ServiceTest do
  use ExUnit.Case, async: true

  defmodule CoreAdapter do
    @behaviour Tay.Core.API

    def enqueue(owner, task, args, options) do
      send(owner, {:enqueue, task, args, options})

      {:ok,
       %{
         id: "00000000000000000000000000000001",
         worker_key: task,
         args: args,
         state: :available,
         attempt: 0,
         max_attempts: 1,
         queue: "default",
         durability: :persistent,
         scheduled_at: nil,
         completed_at: nil,
         errors: []
       }}
    end

    def get_job(owner, id) do
      send(owner, {:get_job, id})
      {:error, :not_found}
    end

    def cancel(owner, id) do
      send(owner, {:cancel, id})
      {:error, :not_found}
    end

    def result(owner, id) do
      send(owner, {:result, id})
      :missing
    end

    def register_schedule(_, _), do: {:error, :unsupported}
    def cancel_schedule(_, _, _), do: {:error, :unsupported}
    def advance_schedule(_, _, _, _, _, _), do: {:error, :unsupported}
  end

  defmodule ScheduleAdapter do
    @behaviour Tay.Schedule.API

    def register(owner, fields) do
      send(owner, {:register_schedule, fields})
      {:ok, %{"id" => "daily"}}
    end

    def cancel(owner, id) do
      send(owner, {:cancel_schedule, id})
      {:ok, %{"id" => id}}
    end
  end

  test "routes Protocol v1 commands through application ports" do
    context = %{core: {CoreAdapter, self()}, schedule: {ScheduleAdapter, self()}}

    assert {:ok, "enqueued", %{"job_id" => "00000000000000000000000000000001"}} =
             Tay.Protocol.Service.handle(context, %{
               "type" => "enqueue",
               "task" => "portable.task",
               "args" => %{"value" => 1}
             })

    assert_receive {:enqueue, "portable.task", %{"value" => 1}, options}
    assert options[:timeout_ms] == 30_000

    assert {:ok, "scheduled", %{"schedule_id" => "daily"}} =
             Tay.Protocol.Service.handle(context, %{
               "type" => "schedule",
               "declaration_id" => "daily"
             })

    assert_receive {:register_schedule, %{"declaration_id" => "daily"}}
  end
end
