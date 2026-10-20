defmodule Tay.Storage.Writer.Config do
  @moduledoc false

  alias Tay.Storage.Segment

  @default_rotation_target_bytes 67_108_864
  @default_timeout_ms 10_000
  @test Mix.env() == :test

  def new(options) do
    allowed =
      [
        :name,
        :data_dir,
        :durability,
        :validated_filesystem,
        :rotation_target_bytes,
        :bootstrap,
        :lifecycle_observer,
        :timeout
      ] ++ test_option_keys()

    with true <- Keyword.keyword?(options) || {:error, :invalid_writer_options},
         true <-
           length(Keyword.keys(options)) == length(Enum.uniq(Keyword.keys(options))) ||
             {:error, :duplicate_writer_options},
         true <-
           Enum.all?(Keyword.keys(options), &(&1 in allowed)) ||
             {:error, :unknown_writer_option},
         {:ok, config} <- Tay.Config.new(data_dir: Keyword.get(options, :data_dir)),
         true <- config.data_dir != nil || {:error, :data_dir_required} do
      options
      |> Enum.into(defaults(config.data_dir))
      |> Map.put(:data_dir, config.data_dir)
      |> validate()
    end
  end

  defp defaults(data_dir) do
    %{
      data_dir: data_dir,
      durability: :sync,
      validated_filesystem: false,
      rotation_target_bytes: @default_rotation_target_bytes,
      bootstrap: false,
      timeout: @default_timeout_ms,
      test_helper: false,
      lifecycle_observer: nil,
      on_transition: nil
    }
  end

  defp validate(options) do
    cond do
      options.lifecycle_observer != nil and not is_pid(options.lifecycle_observer) ->
        {:error, :invalid_lifecycle_observer}

      options.durability not in [:write, :sync] ->
        {:error, :invalid_durability}

      not is_boolean(options.validated_filesystem) ->
        {:error, :invalid_filesystem_validation}

      not is_boolean(options.bootstrap) ->
        {:error, :invalid_bootstrap_intent}

      not is_integer(options.timeout) or options.timeout <= 0 ->
        {:error, :invalid_timeout}

      not is_integer(options.rotation_target_bytes) or
        options.rotation_target_bytes < Segment.min_rotation_bytes() or
          options.rotation_target_bytes > Segment.max_bytes() ->
        {:error, :invalid_rotation_target}

      true ->
        {:ok, options}
    end
  end

  if @test do
    defp test_option_keys, do: [:test_helper, :on_transition]
  else
    defp test_option_keys, do: []
  end
end
