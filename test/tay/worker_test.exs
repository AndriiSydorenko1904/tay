defmodule Tay.WorkerTest do
  use ExUnit.Case, async: true

  defmodule ExampleWorker do
    @behaviour Tay.Worker

    @impl true
    def perform(%Tay.Job{args: %{"send_to" => recipient}} = job) do
      send(recipient, {:performed, job})
      :ok
    end
  end

  test "a behaviour implementation accepts an in-memory job without inserting it" do
    job = %Tay.Job{worker: ExampleWorker, args: %{"send_to" => self()}}

    assert :ok = ExampleWorker.perform(job)

    assert_received {:performed,
                     %Tay.Job{
                       id: nil,
                       state: nil,
                       attempt: 0,
                       inserted_at: nil,
                       scheduled_at: nil,
                       attempted_at: nil,
                       completed_at: nil
                     }}
  end
end
