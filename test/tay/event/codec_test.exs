defmodule Tay.Event.CodecTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Tay.Event
  alias Tay.Event.{Value, V1}
  alias Tay.Storage.Record
  alias Tay.Test.EventHelpers, as: H

  test "every unassigned value tag and every truncated literal Event payload is rejected" do
    for tag <- 10..255 do
      assert {:error, :unknown_tag} = Value.decode(<<tag>>)
    end

    # ETF-looking bytes do not select an alternate decoder.
    assert {:error, :unknown_tag} = Value.decode(<<131, 116, 0, 0, 0, 0>>)

    for id <- ~w(E1 E2 E3 E4 E5 E6) do
      {:ok, record, <<>>} = Record.decode(H.fixture(id))

      for n <- 0..(byte_size(record.payload) - 1) do
        assert {:error, _} =
                 Event.decode_payload(
                   record.record_type,
                   1,
                   binary_part(record.payload, 0, n),
                   Value.defaults()
                 )
      end

      assert {:error, :trailing_bytes} =
               Event.decode_payload(
                 record.record_type,
                 1,
                 record.payload <> <<0>>,
                 Value.defaults()
               )
    end
  end

  test "50 approved literal hashes, and exact positive frame encoding independent of decoding" do
    assert length(H.manifest()) == 50

    for {id, hash} <- H.manifest() do
      assert Base.encode16(:crypto.hash(:sha256, H.fixture(id)), case: :lower) == hash
    end

    for id <- ~w(E1 E2 E3 E4 E5 E6) do
      bytes = H.fixture(id)
      assert {:ok, record, <<>>} = Record.decode(bytes)

      assert {:ok, event, consumed} =
               Event.decode_payload(record.record_type, 1, record.payload, Value.defaults())

      assert event === H.expected(id)
      assert consumed == byte_size(record.payload)
      assert {:ok, {type, 1, payload}} = Event.encode(H.expected(id))
      assert type == record.record_type
      assert payload == record.payload
      assert {:ok, ^bytes} = Record.encode(%{record | payload: payload})
    end
  end

  test "literal primitive boundaries preserve bits and UTF-8 without normalization" do
    for {id, _} <- H.manifest(), String.starts_with?(id, "V") do
      literal = H.fixture(id)
      assert {:ok, value} = Value.decode(literal)
      assert {:ok, ^literal} = Value.encode(value)
    end

    for {id, _} <- H.manifest(), String.starts_with?(id, "X") or id in ~w(N1 N2 N3 N4) do
      assert {:error, _} = Value.decode(H.fixture(id))
    end

    assert {:ok, -9_223_372_036_854_775_808} = Value.decode(H.fixture("V03"))
    assert {:ok, 18_446_744_073_709_551_615} = Value.decode(H.fixture("V08"))
    assert {:ok, "é"} = Value.decode(H.fixture("V16"))
    assert {:ok, "é"} = Value.decode(H.fixture("V17"))
    assert H.fixture("V16") != H.fixture("V17")
    assert :ok = Event.check_runtime()
  end

  test "negative exact schema vectors and physically valid transition-negative frame" do
    for {id, type} <- [{"N5", 5}, {"N6", 5}, {"N8", 4}] do
      assert {:error, _} = Event.decode_payload(type, 1, H.fixture(id), Value.defaults())
    end

    assert {:ok, bad, <<>>} = Record.decode(H.fixture("N7"))
    assert {:ok, event, _} = Event.decode_payload(3, 1, bad.payload, Value.defaults())
    assert event.data["attempt"] == 2
  end

  test "every key is mandatory, extra fields and runtime/opaque args are forbidden" do
    for id <- ~w(E1 E2 E3 E4 E5 E6) do
      event = H.expected(id)

      for key <- Map.keys(event.data) do
        assert {:error, _} = Event.encode(%{event | data: Map.delete(event.data, key)})
      end

      assert {:error, _} = Event.encode(%{event | data: Map.put(event.data, "extra", nil)})
    end

    for arg <- [self(), make_ref(), fn -> :ok end, :unsafe, {:bytes, "a"}, %Tay.Job{}, <<255>>] do
      event = H.inserted(H.definition(%{"args" => %{"x" => arg}}))
      assert {:error, _} = Event.encode(event)
    end

    for key <- Map.keys(H.definition()) do
      assert {:error, _} = Event.encode(H.inserted(Map.delete(H.definition(), key)))
    end

    assert {:ok, _} =
             Event.encode(
               H.inserted(H.definition(%{"args" => %{"" => <<0>>, "x" => [true, false, nil]}}))
             )

    for key <- ["", <<0>>, String.duplicate("w", 256)] do
      assert {:error, _} = Event.encode(H.inserted(H.definition(%{"worker_key" => key})))
    end
  end

  test "primitive numeric domains and schema versions cannot be coerced" do
    for n <- [-9_223_372_036_854_775_809, 18_446_744_073_709_551_616] do
      assert {:error, _} = Value.encode(n)
    end

    for {key, values} <- [
          {"max_attempts", [0, 65_536, 1.0]},
          {"timeout_ms", [0, 86_400_001, 30_000.0]},
          {"definition_version", [2, 1.0]},
          {"scheduled_at", [-1, V1.max_time() + 1, 1.0]}
        ],
        n <- values do
      assert {:error, _} = Event.encode(H.inserted(H.definition(%{key => n})))
    end

    for pair <- [{0, 1}, {255, 1}, {47, 3}, {1, 0}, {1, 2}, {1.0, 1}, {1, 1.0}] do
      {t, s} = pair
      refute Event.supported_schema?(t, s)
      assert {:error, _} = Event.decode_payload(t, s, <<>>, Value.defaults())
    end

    for t <- 1..6, do: assert(Event.supported_schema?(t, 1))

    for policy_key <- Map.keys(V1.policy()) do
      changed = Map.update!(V1.policy(), policy_key, &(&1 + 1))
      assert {:error, _} = Event.encode(H.inserted(H.definition(%{"retry_policy" => changed})))
    end
  end

  test "job ID requires opaque tag 07, and code-only diagnostics have exact 44-byte form" do
    event = H.expected("E5")
    wrong_id = String.duplicate("a", 16)
    {:ok, payload} = Value.encode(%{event.data | "job_id" => wrong_id})
    assert {:error, _} = Event.decode_payload(5, 1, payload, Value.defaults())
    {:ok, diag} = Value.encode(%{"code" => 1, "version" => 1})
    assert byte_size(diag) == 44

    for changed <- [
          %{"code" => 1, "version" => 1, "message" => "secret"},
          %{"code" => 7, "version" => 1},
          %{"code" => 1.0, "version" => 1}
        ] do
      e = H.expected("E4")
      assert {:error, _} = Event.encode(%{e | data: Map.put(e.data, "diagnostic", changed)})
    end
  end

  test "exact resource counters, retryable failures and detached frame substrings" do
    {:ok, record, _} = Record.decode(H.fixture("E1"))
    exact = %{depth: 4, output_nodes: 35, binary_bytes: 185}
    assert {:ok, _, _} = Event.decode_payload(1, 1, record.payload, exact)

    for key <- Map.keys(exact) do
      limits = Map.update!(exact, key, &(&1 - 1))

      assert {:error, {:resource_limit, ^key}} =
               Event.decode_payload(1, 1, record.payload, limits)
    end

    {:ok, value} = Value.decode(record.payload)

    assert {:ok, %{depth: 4, nodes: 35, binary_bytes: 185, encoded_bytes: 404}} =
             Value.measure(value)

    assert :binary.referenced_byte_size(value["definition"]["worker_key"]) == 1

    assert {:error, {:resource_limit, :output_nodes}} =
             Value.decode(<<8, 1000::32, 0::size(8000)>>, %{exact | output_nodes: 10})

    assert {:error, _} = Value.decode(<<9, 0xFFFFFFFF::32>>)

    assert {:error, {:resource_limit, :encoded_bytes}} =
             Value.encode(String.duplicate("x", 100), Value.defaults(), 20)
  end

  property "bounded nested inert values have canonical round trips" do
    leaf =
      one_of([
        integer(-1_000_000..1_000_000),
        string(:utf8, max_length: 20),
        boolean(),
        constant(nil)
      ])

    values =
      tree(leaf, fn child ->
        one_of([
          list_of(child, max_length: 5),
          map_of(string(:alphanumeric, max_length: 8), child, max_length: 5)
        ])
      end)

    check all(value <- values, max_runs: 200) do
      assert {:ok, bytes} = Value.encode(value)
      assert {:ok, ^value} = Value.decode(bytes)
      assert {:ok, ^bytes} = Value.encode(value)
    end
  end

  property "arbitrary payloads never crash the value or Event decoder" do
    check all(bytes <- binary(max_length: 1024), max_runs: 300) do
      assert match?({:ok, _}, Value.decode(bytes)) or match?({:error, _}, Value.decode(bytes))
      assert match?({:error, _}, Event.decode_payload(1, 1, bytes, Value.defaults()))
    end
  end
end
