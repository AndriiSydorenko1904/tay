defmodule Tay.Engine.AdmissionTest do
  use ExUnit.Case, async: false
  alias Tay.Engine.{Admission, Config, Lifecycle}
  alias Tay.Test.EngineHelpers, as: H
  @name __MODULE__
  setup do
    {:ok, config} =
      Config.new(
        data_dir: "tmp/unused-admission",
        name: @name,
        durability: :write,
        client_slots: 1,
        client_bytes: 1024
      )

    {:ok, guardian} = Lifecycle.start_link(config)
    {:ok, generation} = GenServer.call(guardian, {:attach_engine, self()})
    :ok = GenServer.call(guardian, {:attach_writer, self()})
    :ok = GenServer.call(guardian, {:ready, %{jobs: 0}})
    {:ok, meta} = Admission.metadata(@name)
    on_exit(fn -> if Process.alive?(guardian), do: GenServer.stop(guardian) end)
    %{guardian: guardian, generation: generation, meta: meta}
  end

  test "bytes and count are reserved before payload; submitted timeout does not release", %{
    meta: m,
    guardian: g
  } do
    assert {:error, %{kind: :capacity, reason: :client_bytes}} =
             Admission.request(@name, m, :body, 1025, :insert, "id", 50)

    parent = self()

    spawn(fn ->
      send(parent, {:result, Admission.request(@name, m, :body, 1024, :insert, "id", 30)})
    end)

    assert_receive {:command, _, {slot, token}, :body, from}
    assert_receive {:result, {:error, %{kind: :unknown_outcome}}}

    assert {:error, %{reason: :client_slots}} =
             Admission.request(@name, m, :other, 256, :get_job, nil, 50)

    assert Tay.status(name: @name).client_slots_used == 1
    send(g, {:completed, self(), slot, token, from, :late, %{jobs: 1}})
    assert H.eventually(fn -> Tay.status(name: @name).client_slots_used == 0 end)

    assert Tay.status(name: @name).client_slot_states == %{
             free: 1,
             claimed: 0,
             reserved: 0,
             submitted: 0
           }
  end

  test "owner death after grant but before submit reclaims; abandoned pre-grant claim reaps", %{
    meta: m,
    guardian: g
  } do
    parent = self()

    for granted <- [false, true] do
      owner =
        spawn(fn ->
          {:ok, permit} = Admission.claim(@name, m, 2000)
          if granted, do: :ok = GenServer.call(g, {:reserve, m.generation, permit})
          send(parent, {:claimed, self()})

          receive do
            :die -> :ok
          end
        end)

      assert_receive {:claimed, ^owner}
      send(owner, :die)
      assert H.eventually(fn -> Tay.status(name: @name).client_slots_used == 0 end)
    end

    refute_receive {:command, _, _, _, _}
  end

  test "DOWN after submission never frees an in-flight permit", %{meta: m, guardian: g} do
    owner = spawn(fn -> Admission.request(@name, m, :body, 256, :insert, "id", 2000) end)
    assert_receive {:command, _, {slot, token}, :body, from}
    Process.exit(owner, :kill)
    Process.sleep(120)
    assert Tay.status(name: @name).client_slots_used == 1
    send(g, {:completed, self(), slot, token, from, :late, %{}})
    assert H.eventually(fn -> Tay.status(name: @name).client_slots_used == 0 end)
  end

  test "stale generation and stale permit never forward", %{meta: m, guardian: g} do
    {:ok, permit} = Admission.claim(@name, m, 1000)
    assert {:error, :unavailable} = GenServer.call(g, {:reserve, make_ref(), permit})
    assert {:error, _} = GenServer.call(g, {:submit, m.generation, permit, :body})
    refute_receive {:command, _, _, _, _}
  end

  test "a stale completion cannot release or reply to a newer submitted permit", %{
    meta: m,
    guardian: g
  } do
    parent = self()

    first =
      Task.async(fn ->
        Admission.request(@name, m, :first, 256, :insert, "first", 2_000)
      end)

    assert_receive {:command, _, {slot, old_token}, :first, old_from}
    send(g, {:completed, self(), slot, old_token, old_from, :first_ok, %{}})
    assert :first_ok = Task.await(first)

    second =
      Task.async(fn ->
        result = Admission.request(@name, m, :second, 256, :insert, "second", 2_000)
        send(parent, {:second_result, result})
      end)

    assert_receive {:command, _, {^slot, new_token}, :second, new_from}
    refute new_token == old_token

    send(g, {:completed, self(), slot, old_token, old_from, :stale, %{}})
    assert Tay.status(name: @name).client_slot_states.submitted == 1
    refute_receive {:second_result, _}, 20

    send(g, {:completed, self(), slot, new_token, new_from, :second_ok, %{}})
    assert_receive {:second_result, :second_ok}
    Task.await(second)
    assert Tay.status(name: @name).client_slot_states.free == 1
  end
end
