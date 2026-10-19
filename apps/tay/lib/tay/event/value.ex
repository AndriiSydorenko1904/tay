defmodule Tay.Event.Value do
  @moduledoc """
  Canonical inert Event v1 values. `{:bytes, binary}` is an internal tag-07
  carrier, not a general tuple encoding; Event schemas restrict its placement.
  Measurement validates/budgets input before materializing output. Decoding
  detaches retained strings from their backing frame and consumes exactly once.
  """
  import Bitwise
  @max 16_777_216
  @defaults %{depth: 64, output_nodes: 100_000, binary_bytes: @max}
  def defaults, do: @defaults

  def limits?(x),
    do:
      is_map(x) and map_size(x) == 3 and is_integer(x[:depth]) and x.depth > 0 and
        is_integer(x[:output_nodes]) and x.output_nodes > 0 and
        is_integer(x[:binary_bytes]) and x.binary_bytes >= 0

  def measure(value, limits \\ @defaults, max_bytes \\ @max) do
    with :ok <- options(limits, max_bytes) do
      protect(fn ->
        state = measure_value(value, 1, state(limits, max_bytes))
        Map.take(state, [:depth, :nodes, :binary_bytes, :encoded_bytes])
      end)
    end
  end

  def encode(value, limits \\ @defaults, max_bytes \\ @max) do
    with {:ok, _} <- measure(value, limits, max_bytes),
         do: {:ok, value |> wire() |> IO.iodata_to_binary()}
  end

  def decode(bytes, limits \\ @defaults) do
    with :ok <- options(limits, @max),
         true <- is_binary(bytes) || {:error, :invalid_input},
         true <- byte_size(bytes) <= @max || {:error, :payload_hard_limit} do
      protect(fn ->
        {value, rest, _} = read(bytes, 1, state(limits, @max))
        if rest != <<>>, do: invalid(:trailing_bytes)
        value
      end)
    end
  end

  defp options(limits, max_bytes) do
    if limits?(limits) and is_integer(max_bytes) and max_bytes in 0..@max,
      do: :ok,
      else: {:error, :invalid_value_limits}
  end

  defp state(limits, max_bytes),
    do: %{
      limits: limits,
      max_bytes: max_bytes,
      depth: 0,
      nodes: 0,
      binary_bytes: 0,
      encoded_bytes: 0
    }

  defp protect(fun) do
    {:ok, fun.()}
  catch
    {:value_error, reason} -> {:error, reason}
  end

  defp invalid(reason), do: throw({:value_error, reason})
  @spec budget(term()) :: no_return()
  defp budget(key), do: invalid({:resource_limit, key})

  defp node(state, depth) do
    if depth > state.limits.depth, do: budget(:depth)
    if state.nodes >= state.limits.output_nodes, do: budget(:output_nodes)
    %{state | nodes: state.nodes + 1, depth: max(depth, state.depth)}
  end

  defp encoded(state, bytes) do
    n = state.encoded_bytes + bytes
    if n > state.max_bytes, do: budget(:encoded_bytes)
    %{state | encoded_bytes: n}
  end

  defp binary_charge(state, n) do
    if n > 4_294_967_295, do: invalid(:length)
    n = state.binary_bytes + n
    if n > state.limits.binary_bytes, do: budget(:binary_bytes)
    %{state | binary_bytes: n}
  end

  defp children(state, n) do
    if n > state.limits.output_nodes - state.nodes, do: budget(:output_nodes)
    state
  end

  defp measure_value(value, depth, state) do
    state = node(state, depth)

    cond do
      value in [nil, false, true] ->
        encoded(state, 1)

      is_integer(value) and value >= -9_223_372_036_854_775_808 and
          value <= 18_446_744_073_709_551_615 ->
        encoded(state, 9)

      is_float(value) ->
        <<bits::64>> = <<value::float-big-64>>
        if (bits >>> 52 &&& 2047) == 2047, do: invalid(:nonfinite_float)
        encoded(state, 9)

      is_binary(value) ->
        state = state |> binary_charge(byte_size(value)) |> encoded(5 + byte_size(value))
        if not String.valid?(value), do: invalid(:utf8)
        state

      is_tuple(value) and tuple_size(value) == 2 and elem(value, 0) == :bytes and
          is_binary(elem(value, 1)) ->
        n = byte_size(elem(value, 1))
        state |> binary_charge(n) |> encoded(5 + n)

      is_map(value) and not is_struct(value) ->
        n = map_size(value)
        if n > 4_294_967_295, do: invalid(:count)
        state = state |> encoded(5) |> children(2 * n)
        measure_map(:maps.iterator(value), depth + 1, state)

      is_list(value) ->
        measure_list(value, depth + 1, encoded(state, 5), 0)

      true ->
        invalid(:invalid_value)
    end
  end

  defp measure_map(iterator, depth, state) do
    case :maps.next(iterator) do
      :none ->
        state

      {key, value, next} ->
        if not is_binary(key), do: invalid(:map_key)
        state = measure_value(key, depth, state)
        measure_map(next, depth, measure_value(value, depth, state))
    end
  end

  defp measure_list([], _, state, _), do: state

  defp measure_list([head | tail], depth, state, n) when n < 4_294_967_295,
    do: measure_list(tail, depth, measure_value(head, depth, state), n + 1)

  defp measure_list(_, _, _, _), do: invalid(:list)

  defp wire(nil), do: <<0>>
  defp wire(false), do: <<1>>
  defp wire(true), do: <<2>>
  defp wire(n) when is_integer(n) and n < 0, do: <<3, n::signed-big-64>>
  defp wire(n) when is_integer(n), do: <<4, n::unsigned-big-64>>
  defp wire(f) when is_float(f), do: <<5, f::float-big-64>>
  defp wire(s) when is_binary(s), do: [<<6, byte_size(s)::32>>, s]
  defp wire({:bytes, s}), do: [<<7, byte_size(s)::32>>, s]
  defp wire(list) when is_list(list), do: [<<8, length(list)::32>>, Enum.map(list, &wire/1)]

  defp wire(map),
    do: [<<9, map_size(map)::32>>, Enum.map(Enum.sort(map), fn {k, v} -> [wire(k), wire(v)] end)]

  defp read(bytes, depth, state) do
    state = node(state, depth)

    case bytes do
      <<0, rest::binary>> ->
        {nil, rest, state}

      <<1, rest::binary>> ->
        {false, rest, state}

      <<2, rest::binary>> ->
        {true, rest, state}

      <<3, n::signed-big-64, rest::binary>> when n < 0 ->
        {n, rest, state}

      <<3, _::64, _::binary>> ->
        invalid(:noncanonical_integer)

      <<4, n::unsigned-big-64, rest::binary>> ->
        {n, rest, state}

      <<5, bits::64, rest::binary>> ->
        if (bits >>> 52 &&& 2047) == 2047, do: invalid(:nonfinite_float)
        <<f::float-big-64>> = <<bits::64>>
        {f, rest, state}

      <<tag, n::32, rest::binary>> when tag in [6, 7] ->
        if n > byte_size(rest), do: invalid(:truncated_value)
        state = binary_charge(state, n)
        <<body::binary-size(^n), rest::binary>> = rest
        if tag == 6 and not String.valid?(body), do: invalid(:utf8)
        body = :binary.copy(body)
        {if(tag == 7, do: {:bytes, body}, else: body), rest, state}

      <<8, n::32, rest::binary>> ->
        if n > byte_size(rest), do: invalid(:truncated_value)
        read_list(n, rest, depth + 1, children(state, n), [])

      <<9, n::32, rest::binary>> ->
        if 6 * n > byte_size(rest), do: invalid(:truncated_value)
        read_map(n, rest, depth + 1, children(state, 2 * n), %{}, nil)

      <<tag, _::binary>> when tag > 9 ->
        invalid(:unknown_tag)

      _ ->
        invalid(:truncated_value)
    end
  end

  defp read_list(0, rest, _, state, acc), do: {Enum.reverse(acc), rest, state}

  defp read_list(n, bytes, depth, state, acc) do
    {v, rest, state} = read(bytes, depth, state)
    read_list(n - 1, rest, depth, state, [v | acc])
  end

  defp read_map(0, rest, _, state, map, _), do: {map, rest, state}

  defp read_map(n, bytes, depth, state, map, previous) do
    {key, rest, state} = read(bytes, depth, state)
    if not is_binary(key), do: invalid(:map_key)
    if previous != nil and key <= previous, do: invalid(:map_order)
    {value, rest, state} = read(rest, depth, state)
    read_map(n - 1, rest, depth, state, Map.put(map, key, value), key)
  end
end
