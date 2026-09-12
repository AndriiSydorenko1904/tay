defmodule Tay.Engine.PublicMutationTest do
  use ExUnit.Case, async: false
  alias Tay.Engine.{Admission, Config, Lifecycle}
  alias Tay.Test.EngineHelpers, as: H
  @name __MODULE__

  setup do
    {:ok, config} =
      Config.new(
        data_dir: "tmp/unused-public-mutation",
        name: @name,
        durability: :write,
        client_slots: 2,
        client_bytes: 1024
      )

    {:ok, guardian} = Lifecycle.start_link(config)
    {:ok, generation} = GenServer.call(guardian, {:attach_engine, self()})
    :ok = GenServer.call(guardian, {:attach_writer, self()})
    :ok = GenServer.call(guardian, {:ready, %{jobs: 1}})
    raw = <<1::128>>
    revision = {:tay_revision, <<2::128>>, raw, generation, 3}
    on_exit(fn -> if Process.alive?(guardian), do: GenServer.stop(guardian) end)

    %{
      guardian: guardian,
      generation: generation,
      revision: revision,
      id: Tay.JobID.encode(raw),
      raw: raw
    }
  end

  defp request(operation, id, options) do
    parent = self()
    ref = make_ref()
    spawn(fn -> send(parent, {ref, apply(Tay, operation, [id, options])}) end)
    ref
  end

  defp reply(guardian, {slot, token}, from, result) do
    # This test process stands in for Engine; finish the command before making
    # its reply visible so a one-capture request can claim its next finite slot.
    send(guardian, {:completed, self(), slot, token, %{}})
    assert H.eventually(fn -> :ets.lookup(@name, slot) == [{slot, nil, nil, :free, 0}] end)
    GenServer.reply(from, result)
  end

  test "an explicit revision submits exactly one bounded intent, without lookup or refresh", c do
    for operation <- [:cancel, :retry] do
      ref = request(operation, c.id, name: @name, expected_revision: c.revision)
      raw = c.raw
      revision = c.revision
      generation = c.generation
      assert_receive {:command, ^generation, permit, {^operation, ^raw, ^revision}, from}

      reply(c.guardian, permit, from, {:error, Tay.Error.new(:conflict, :revision_conflict)})

      assert_receive {^ref,
                      {:error,
                       %Tay.Error{
                         kind: :conflict,
                         reason: :revision_conflict,
                         job_id: id,
                         operation: ^operation,
                         expected_revision: ^revision
                       }}}

      assert id == c.id
      refute_receive {:command, _, _, _, _}
    end
  end

  test "omitted revision captures once then preserves that context on mutation conflict", c do
    for operation <- [:cancel, :retry] do
      ref = request(operation, c.id, name: @name)
      raw = c.raw
      revision = c.revision
      assert_receive {:command, _, permit, {:get, ^raw}, from}
      reply(c.guardian, permit, from, {:ok, %Tay.Job{id: c.id, revision: revision}})
      assert_receive {:command, _, permit, {^operation, ^raw, ^revision}, from}
      reply(c.guardian, permit, from, {:error, Tay.Error.new(:conflict, :state_conflict)})

      assert_receive {^ref,
                      {:error,
                       %Tay.Error{
                         kind: :conflict,
                         operation: ^operation,
                         expected_revision: ^revision
                       }}}

      refute_receive {:command, _, _, _, _}
    end
  end

  test "submitted mutation timeout is unknown, preserves captured context, and cannot free its slot",
       c do
    for operation <- [:cancel, :retry] do
      ref = request(operation, c.id, name: @name, timeout: 30, expected_revision: c.revision)
      assert_receive {:command, _, {slot, token}, {^operation, _, _}, from}

      assert_receive {^ref,
                      {:error,
                       %Tay.Error{
                         kind: :unknown_outcome,
                         reason: :submitted_request_lost,
                         operation: ^operation,
                         expected_revision: revision,
                         job_id: id
                       }}}

      assert revision == c.revision and id == c.id
      assert [{^slot, ^token, _, :submitted, _}] = :ets.lookup(@name, slot)
      refute_receive {:command, _, _, _, _}
      reply(c.guardian, {slot, token}, from, {:ok, %Tay.Job{id: c.id}})
    end
  end

  test "capture failure submits no mutation, and a provided old-generation token is never refreshed",
       c do
    for operation <- [:cancel, :retry] do
      ref = request(operation, c.id, name: @name)
      assert_receive {:command, _, permit, {:get, _}, from}
      reply(c.guardian, permit, from, {:error, :not_found})
      assert_receive {^ref, {:error, :not_found}}
      refute_receive {:command, _, _, _, _}

      stale = put_elem(c.revision, 3, make_ref())
      ref = request(operation, c.id, name: @name, expected_revision: stale)
      assert_receive {:command, _, permit, {^operation, _, ^stale}, from}
      reply(c.guardian, permit, from, {:error, Tay.Error.new(:conflict, :revision_conflict)})
      assert_receive {^ref, {:error, %Tay.Error{expected_revision: ^stale}}}
      refute_receive {:command, _, _, _, _}
    end
  end

  test "malformed revision/options/id are rejected before admission and never echoed into errors",
       c do
    oversized = String.duplicate("sensitive", 100_000)

    invalid_revisions = [
      nil,
      oversized,
      {:tay_revision, <<0>>, c.raw, c.generation, 1},
      {:tay_revision, <<0::128>>, oversized, c.generation, 1},
      {:tay_revision, <<0::128>>, c.raw, self(), 1},
      {:tay_revision, <<0::128>>, c.raw, c.generation, 0},
      {:tay_revision, <<0::128>>, c.raw, c.generation, 18_446_744_073_709_551_616},
      {:tay_revision, <<0::128>>, c.raw, c.generation, 1.0}
    ]

    for operation <- [:cancel, :retry] do
      for revision <- invalid_revisions do
        assert {:error, %Tay.Error{kind: :invalid, expected_revision: nil}} =
                 apply(Tay, operation, [c.id, [name: @name, expected_revision: revision]])
      end

      for options <- [
            [name: @name, timeout: :infinity],
            [name: @name, expected_revision: c.revision, expected_revision: c.revision],
            [name: @name, arbitrary: :option],
            [name: @name, timeout: 0],
            [name: nil],
            :not_options
          ] do
        assert {:error, %Tay.Error{kind: :invalid}} = apply(Tay, operation, [c.id, options])
      end

      assert {:error, %Tay.Error{kind: :invalid, job_id: nil}} =
               apply(Tay, operation, [oversized, [name: @name, expected_revision: c.revision]])
    end

    assert Tay.status(name: @name).client_slots_used == 0
    refute_receive {:command, _, _, _, _}
  end

  test "bounded capacity refusals retain a validated revision without unknown outcome", c do
    {:ok, meta} = Admission.metadata(@name)

    for operation <- [:cancel, :retry] do
      assert {:error,
              %Tay.Error{
                kind: :capacity,
                reason: :client_bytes,
                expected_revision: revision,
                operation: ^operation
              }} =
               Admission.request(
                 @name,
                 meta,
                 {operation, c.raw, c.revision},
                 meta.slot_bytes + 1,
                 operation,
                 c.id,
                 30,
                 c.revision
               )

      assert revision == c.revision
    end

    refute_receive {:command, _, _, _, _}
  end
end
