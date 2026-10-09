defmodule Tay.Test.Environment do
  @moduledoc false

  def validate! do
    case System.get_env("TAY_TEST_DATA_ROOT") do
      nil ->
        :ok

      root ->
        validate_root!(root)
    end
  end

  defp validate_root!(root) do
    unless Path.type(root) == :absolute do
      raise "TAY_TEST_DATA_ROOT must be an absolute path, got: #{inspect(root)}"
    end

    File.mkdir_p!(root)

    case symlink_component(root) do
      nil ->
        :ok

      component ->
        raise """
        TAY_TEST_DATA_ROOT contains a symbolic-link path component that Tay's native
        ownership boundary intentionally refuses: #{component}

        Set TAY_TEST_DATA_ROOT to the canonical physical path, or unset it to use
        the repository-local test directory. On macOS, prefer /private/var/... over
        /var/....
        """
    end
  end

  defp symlink_component(path) do
    path
    |> Path.split()
    |> Enum.reduce_while(nil, fn part, current ->
      candidate = if is_nil(current), do: part, else: Path.join(current, part)

      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, candidate}
        {:ok, _} -> {:cont, candidate}
        {:error, _} -> {:halt, candidate}
      end
    end)
    |> case do
      value when is_binary(value) ->
        case File.lstat(value) do
          {:ok, %File.Stat{type: :symlink}} -> value
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
