# Permanent Tay v1 compatibility anchors, copied from the approved RFC §18.1.
# These hex literals are not produced by Tay.Storage.Record or a checksum implementation.
# Numeric identifiers carry no Event meaning. All fixtures use default decode resources.
[
  %{
    id: "F01",
    file: "f01.bin",
    hex: "544159000101000100000000000000010000000044EA307B44EA307B",
    result:
      {:ok,
       %{
         format_version: 1,
         record_type: 1,
         flags: 0,
         payload_schema_version: 1,
         sequence: 1,
         payload: <<>>
       }, <<>>}
  },
  %{
    id: "F02",
    file: "f02.bin",
    hex: "5441590001010001000000000000000200000009746B5B4300FF544159007F800A4E6783E1",
    result:
      {:ok,
       %{
         format_version: 1,
         record_type: 1,
         flags: 0,
         payload_schema_version: 1,
         sequence: 2,
         payload: <<0, 255, 84, 65, 89, 0, 127, 128, 10>>
       }, <<>>}
  },
  %{
    id: "F03",
    file: "f03.bin",
    hex: "5441590001FE00FFFFFFFFFFFFFFFFFF00000000FA875C6BFA875C6B",
    result:
      {:ok,
       %{
         format_version: 1,
         record_type: 254,
         flags: 0,
         payload_schema_version: 255,
         sequence: 18_446_744_073_709_551_615,
         payload: <<>>
       }, <<>>}
  },
  %{
    id: "F04",
    file: "f04.bin",
    hex: "544159000101000100000000000000010000000144EA307B44EA307B",
    result: {:error, {:corrupt, :header_checksum}}
  },
  %{
    id: "F05",
    file: "f05.bin",
    hex: "5441590001010001000000000000000200000009746B5B4300FF544159007F800A4E6783E0",
    result: {:error, {:corrupt, :record_checksum}}
  },
  %{
    id: "F06",
    file: "f06.bin",
    hex: "54415900020100010000000000000001000000005712508857125088",
    result: {:error, {:unsupported, {:format, 2}}}
  },
  %{
    id: "F07",
    file: "f07.bin",
    hex: "5441590001020001000000000000000100000000EC793778EC793778",
    result:
      {:ok,
       %{
         format_version: 1,
         record_type: 2,
         flags: 0,
         payload_schema_version: 1,
         sequence: 1,
         payload: <<>>
       }, <<>>}
  },
  %{
    id: "F08",
    file: "f08.bin",
    hex: "544159000101010100000000000000010000000010ED653D10ED653D",
    result: {:error, {:unsupported, {:flags, 1}}}
  },
  %{
    id: "F09",
    file: "f09.bin",
    hex: "5441590001010002000000000000000100000000159C78D4159C78D4",
    result:
      {:ok,
       %{
         format_version: 1,
         record_type: 1,
         flags: 0,
         payload_schema_version: 2,
         sequence: 1,
         payload: <<>>
       }, <<>>}
  },
  %{
    id: "F10",
    file: "f10.bin",
    hex: "5441590001FE00FFFFFFFFFFFFFFFFFF0100000027C2F6D3",
    result:
      {:incomplete, :payload,
       %{
         format_version: 1,
         record_type: 254,
         flags: 0,
         payload_schema_version: 255,
         sequence: 18_446_744_073_709_551_615,
         payload_length: 16_777_216,
         record_bytes: 16_777_244,
         available_bytes: 24,
         missing_bytes: 16_777_220
       }}
  },
  %{
    id: "F11",
    file: "f11.bin",
    hex: "54415900010100010000000000000001FFFFFFFFF3728443",
    result: {:error, {:corrupt, {:payload_length_exceeds_format, 4_294_967_295, 16_777_216}}}
  },
  %{
    id: "F12",
    file: "f12.bin",
    hex: "54415900010100010000000000000001010000016BC419C0",
    result: {:error, {:corrupt, {:payload_length_exceeds_format, 16_777_217, 16_777_216}}}
  },
  %{
    id: "F13",
    file: "f13.bin",
    hex: "5441590000010001000000000000000100000000B6E63D85B6E63D85",
    result: {:error, {:corrupt, {:invalid_format, 0}}}
  },
  %{
    id: "F14",
    file: "f14.bin",
    hex: "54415900010000010000000000000001000000002364CD7A2364CD7A",
    result: {:error, {:corrupt, {:reserved_type, 0}}}
  },
  %{
    id: "F15",
    file: "f15.bin",
    hex: "5441590001FF0001000000000000000100000000321C5547321C5547",
    result: {:error, {:corrupt, {:reserved_type, 255}}}
  },
  %{
    id: "F16",
    file: "f16.bin",
    hex: "54415900010100000000000000000001000000007438081E7438081E",
    result: {:error, {:corrupt, {:invalid_schema, 0}}}
  },
  %{
    id: "F17",
    file: "f17.bin",
    hex: "54415900010100010000000000000000000000007CFB5FD77CFB5FD7",
    result: {:error, {:corrupt, {:invalid_sequence, 0}}}
  },
  %{
    id: "F18",
    file: "f18.bin",
    hex: "544159000101000100000000000000030000000034C8EF2334C8EF23",
    result:
      {:ok,
       %{
         format_version: 1,
         record_type: 1,
         flags: 0,
         payload_schema_version: 1,
         sequence: 3,
         payload: <<>>
       }, <<>>}
  }
]
