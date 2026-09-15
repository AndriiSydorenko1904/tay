defmodule Tay.Storage.V2.Retention do
  @moduledoc "Shared normative schema-1 terminal-retention validation and time arithmetic."
  alias Tay.Event.V1
  @hour_ms 3_600_000
  @max_hours div(V1.max_time(), @hour_ms)

  def max_hours, do: @max_hours
  def validate(:infinity), do: :ok
  def validate({:hours, hours}) when is_integer(hours) and hours in 1..@max_hours, do: :ok
  def validate(_), do: {:error, :terminal_retention}

  def duration({:hours, hours} = retention) do
    with :ok <- validate(retention), do: {:ok, hours * @hour_ms}
  end

  def duration(_), do: {:error, :terminal_retention}

  def to_value(:infinity), do: "infinity"
  def to_value({:hours, hours}), do: %{"hours" => hours}

  def from_value("infinity"), do: {:ok, :infinity}

  def from_value(%{"hours" => hours} = value) when map_size(value) == 1 do
    with :ok <- validate({:hours, hours}), do: {:ok, {:hours, hours}}
  end

  def from_value(_), do: {:error, :terminal_retention}

  def expired?(terminal_at, retention, captured_at) do
    with :ok <- validate(retention),
         true <-
           (V1.time?(terminal_at) and V1.time?(captured_at)) ||
             {:error, :retention_timestamp_unavailable} do
      case retention do
        :infinity ->
          {:ok, false}

        {:hours, hours} ->
          duration = hours * @hour_ms
          # No terminal_at + duration overflow; subtraction stays within signed time.
          {:ok, captured_at >= duration and terminal_at <= captured_at - duration}
      end
    end
  end
end
