defmodule Tay.ConfigTest do
  use ExUnit.Case, async: false

  alias Tay.Config

  test "defaults leave the storage location unconfigured" do
    assert {:ok, %Config{data_dir: nil, queues: [default: 10]}} = Config.new([])
    assert {:ok, %Config{data_dir: nil}} = Config.new(data_dir: nil)
  end

  test "normalizes relative paths and preserves explicit queue order" do
    assert {:ok, config} =
             Config.new(data_dir: "var/tay/unused/../dev", queues: [mailers: 2, default: 3])

    assert config.data_dir == Path.join(File.cwd!(), "var/tay/dev")
    assert config.queues == [mailers: 2, default: 3]
  end

  @tag :tmp_dir
  test "normalizes absolute paths without creating a directory", %{tmp_dir: tmp_dir} do
    target = Path.join(tmp_dir, "not-created")
    refute File.exists?(target)

    assert {:ok, %Config{data_dir: ^target}} = Config.new(data_dir: target <> "/child/..")

    refute File.exists?(target)
  end

  test "preserves nonblank path whitespace rather than rewriting it" do
    assert {:ok, config} = Config.new(data_dir: "path with spaces ")
    assert config.data_dir == Path.join(File.cwd!(), "path with spaces ")
  end

  test "accepts no configured queues" do
    assert {:ok, %Config{queues: []}} = Config.new(queues: [])
  end

  test "rejects non-keyword options" do
    for options <- [nil, :invalid, %{}, "options", [:data_dir], [{"data_dir", "path"}]] do
      assert {:error, {:invalid_config, :options, "must be a keyword list"}} =
               Config.new(options)
    end
  end

  test "rejects duplicate and unknown options" do
    assert {:error, {:invalid_config, :options, "must not contain duplicate keys"}} =
             Config.new(data_dir: "first", data_dir: "second")

    assert {:error, {:invalid_config, :options, "only :data_dir and :queues are supported"}} =
             Config.new(typo: true)
  end

  test "rejects invalid path types" do
    for path <- [123, false, :path, ~c"path", [], %{}] do
      assert {:error, {:invalid_config, :data_dir, "must be a path string or nil"}} =
               Config.new(data_dir: path)
    end
  end

  test "rejects blank paths" do
    for path <- ["", " ", "\t\n"] do
      assert {:error, {:invalid_config, :data_dir, "must not be blank"}} =
               Config.new(data_dir: path)
    end
  end

  test "rejects invalid UTF-8 and NUL bytes" do
    assert {:error, {:invalid_config, :data_dir, "must contain valid UTF-8"}} =
             Config.new(data_dir: <<255>>)

    assert {:error, {:invalid_config, :data_dir, "must not contain NUL bytes"}} =
             Config.new(data_dir: <<"path", 0, "suffix">>)
  end

  test "rejects non-keyword queues including string names" do
    for queues <- [nil, %{}, :default, ["default"], [{"default", 10}]] do
      assert {:error, {:invalid_config, :queues, "must be a keyword list with atom queue names"}} =
               Config.new(queues: queues)
    end
  end

  test "rejects duplicate queue names" do
    assert {:error, {:invalid_config, :queues, "queue names must be unique"}} =
             Config.new(queues: [default: 1, default: 2])
  end

  test "rejects invalid concurrency limits" do
    for limit <- [0, -1, 1.5, "10", nil, true] do
      assert {:error, {:invalid_config, :queues, "concurrency limits must be positive integers"}} =
               Config.new(queues: [default: limit])
    end
  end

  test "load reads current application configuration without modifying it" do
    previous_env = Application.get_all_env(:tay)

    on_exit(fn ->
      for {key, _value} <- Application.get_all_env(:tay), do: Application.delete_env(:tay, key)
      for {key, value} <- previous_env, do: Application.put_env(:tay, key, value)
    end)

    Application.put_env(:tay, :data_dir, "var/tay/first")
    Application.put_env(:tay, :queues, mailers: 4)

    assert {:ok, %Config{data_dir: first_path, queues: [mailers: 4]}} = Config.load()
    assert first_path == Path.join(File.cwd!(), "var/tay/first")
    assert Application.get_env(:tay, :data_dir) == "var/tay/first"

    Application.put_env(:tay, :data_dir, "var/tay/second")
    assert {:ok, %Config{data_dir: second_path}} = Config.load()
    assert second_path == Path.join(File.cwd!(), "var/tay/second")

    Application.put_env(:tay, :queues, mailers: 0)
    assert {:error, {:invalid_config, :queues, _message}} = Config.load()
  end
end
