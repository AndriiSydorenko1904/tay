defmodule Tay.Storage.V2AuthorityTest do
  use ExUnit.Case, async: true

  alias Tay.Storage.CRC32C
  alias Tay.Storage.V2.Authority

  @store <<1::128>>
  @epoch <<2::128>>
  @other <<3::128>>
  @digest <<42::256>>

  defp manifest do
    %{
      store_id: @store,
      epoch_id: @epoch,
      source_epoch_id: nil,
      source_frontier: 17,
      captured_at: 1_000,
      terminal_retention: :infinity,
      source_segments: [%{id: 1, digest: @digest}],
      base_segments: [
        %{id: 1, first_sequence: 1, last_sequence: 2, bytes: 480, digest: @digest}
      ],
      tail_segment_id: 2,
      tail_first_sequence: 3
    }
  end

  test "checksummed marker, CURRENT, and manifest select one exact authority" do
    assert {:ok, marker} = Authority.encode_marker(@store)
    assert byte_size(marker) == 28
    assert {:ok, @store} == Authority.decode_marker(marker)

    assert {:ok, manifest_bytes} = Authority.encode_manifest(manifest())
    assert {:ok, decoded} = Authority.decode_manifest(manifest_bytes)
    assert decoded == manifest()

    pointer = %{
      store_id: @store,
      epoch_id: @epoch,
      manifest_digest: Authority.manifest_digest(manifest_bytes)
    }

    assert {:ok, current} = Authority.encode_current(pointer)
    assert byte_size(current) == 76
    assert {:ok, ^pointer} = Authority.decode_current(current)
    assert {:ok, ^decoded} = Authority.verify_selection(marker, current, manifest_bytes)
  end

  test "missing, corrupt, unsupported and mismatched authority metadata fail closed" do
    {:ok, marker} = Authority.encode_marker(@store)
    {:ok, manifest_bytes} = Authority.encode_manifest(manifest())
    digest = Authority.manifest_digest(manifest_bytes)

    {:ok, current} =
      Authority.encode_current(%{store_id: @store, epoch_id: @epoch, manifest_digest: digest})

    assert {:error, :metadata_length} = Authority.decode_current(nil)
    assert {:error, :metadata_length} = Authority.decode_current(binary_part(current, 0, 75))
    assert {:error, :metadata_checksum} = Authority.decode_current(flip_last(current))

    assert {:error, :current_format} =
             Authority.decode_current(
               rechecksum(<<"TAYC", 2, binary_part(current, 5, 67)::binary>>)
             )

    {:ok, wrong_store} = Authority.encode_marker(@other)

    assert {:error, :store_id_mismatch} =
             Authority.verify_selection(wrong_store, current, manifest_bytes)

    {:ok, wrong_epoch} =
      Authority.encode_current(%{store_id: @store, epoch_id: @other, manifest_digest: digest})

    assert {:error, :epoch_mismatch} =
             Authority.verify_selection(marker, wrong_epoch, manifest_bytes)

    {:ok, wrong_digest} =
      Authority.encode_current(%{store_id: @store, epoch_id: @epoch, manifest_digest: @digest})

    assert {:error, :manifest_digest} =
             Authority.verify_selection(marker, wrong_digest, manifest_bytes)
  end

  test "manifest topology and extra fields are refused" do
    assert {:error, :base_segments} =
             Authority.encode_manifest(%{manifest() | tail_first_sequence: 4})

    assert {:error, :base_segments} =
             Authority.encode_manifest(%{manifest() | tail_segment_id: 3})

    assert {:error, :manifest_fields} =
             Authority.encode_manifest(Map.put(manifest(), :unexpected, true))

    assert {:ok, empty} =
             Authority.encode_manifest(%{
               manifest()
               | source_frontier: 0,
                 source_segments: [],
                 base_segments: [],
                 tail_segment_id: 1,
                 tail_first_sequence: 1
             })

    assert {:ok, %{base_segments: [], tail_segment_id: 1}} = Authority.decode_manifest(empty)
  end

  defp flip_last(bytes) do
    size = byte_size(bytes) - 1
    <<prefix::binary-size(^size), last>> = bytes
    <<prefix::binary, Bitwise.bxor(last, 1)>>
  end

  defp rechecksum(body), do: <<body::binary, CRC32C.checksum(body)::32>>
end
