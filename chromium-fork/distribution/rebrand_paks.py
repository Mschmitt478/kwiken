import argparse
import dataclasses
import os
import pathlib
import struct
import tempfile


@dataclasses.dataclass
class DataPackContents:
    resources: dict[int, bytes]
    encoding: int


def read_data_pack(pak_path: pathlib.Path) -> DataPackContents:
    data = pak_path.read_bytes()
    version = struct.unpack("<I", data[:4])[0]
    if version == 4:
        resource_count, encoding = struct.unpack("<IB", data[4:9])
        alias_count = 0
        header_size = 9
    elif version == 5:
        encoding, resource_count, alias_count = struct.unpack("<BxxxHH", data[4:12])
        header_size = 12
    else:
        raise ValueError(f"Unsupported PAK version {version} in {pak_path}")

    def index_entry(index: int) -> tuple[int, int]:
        offset = header_size + index * 6
        return struct.unpack("<HI", data[offset : offset + 6])

    resources: dict[int, bytes] = {}
    previous_id, previous_offset = index_entry(0)
    for index in range(1, resource_count + 1):
        resource_id, offset = index_entry(index)
        resources[previous_id] = data[previous_offset:offset]
        previous_id, previous_offset = resource_id, offset

    alias_table_offset = header_size + (resource_count + 1) * 6
    for index in range(alias_count):
        offset = alias_table_offset + index * 4
        resource_id, aliased_index = struct.unpack("<HH", data[offset : offset + 4])
        aliased_id = index_entry(aliased_index)[0]
        resources[resource_id] = resources[aliased_id]

    return DataPackContents(resources=resources, encoding=encoding)


def write_data_pack(
    resources: dict[int, bytes], output_path: pathlib.Path, encoding: int
) -> None:
    resource_ids = sorted(resources)
    id_by_data = {
        resources[resource_id]: resource_id for resource_id in reversed(resource_ids)
    }
    alias_map = {
        resource_id: id_by_data[value]
        for resource_id, value in resources.items()
        if id_by_data[value] != resource_id
    }
    resource_count = len(resources) - len(alias_map)
    output = [struct.pack("<IBxxxHH", 5, encoding, resource_count, len(alias_map))]
    data_offset = 12 + (resource_count + 1) * 6 + len(alias_map) * 4
    index_by_id: dict[int, int] = {}
    payloads: list[bytes] = []
    index = 0
    for resource_id in resource_ids:
        if resource_id in alias_map:
            continue
        value = resources[resource_id]
        index_by_id[resource_id] = index
        output.append(struct.pack("<HI", resource_id, data_offset))
        data_offset += len(value)
        payloads.append(value)
        index += 1
    output.append(struct.pack("<HI", 0, data_offset))
    for resource_id in sorted(alias_map):
        output.append(struct.pack("<HH", resource_id, index_by_id[alias_map[resource_id]]))
    output.extend(payloads)
    output_path.write_bytes(b"".join(output))


def replace_brand(value: bytes) -> tuple[bytes, int]:
    replacements = 0
    for source, target, protected in (
        (b"Chromium", b"Kwiken", b"Chromium Authors"),
        (
            "Chromium".encode("utf-16-le"),
            "Kwiken".encode("utf-16-le"),
            "Chromium Authors".encode("utf-16-le"),
        ),
    ):
        segments = value.split(protected)
        for index, segment in enumerate(segments):
            count = segment.count(source)
            if count:
                segments[index] = segment.replace(source, target)
                replacements += count
        value = protected.join(segments)
    return value, replacements


def rebrand_pak(pak_path: pathlib.Path) -> tuple[int, int]:
    contents = read_data_pack(pak_path)
    changed_resources = 0
    replacement_count = 0
    for resource_id, value in list(contents.resources.items()):
        branded_value, replacements = replace_brand(value)
        if replacements:
            contents.resources[resource_id] = branded_value
            changed_resources += 1
            replacement_count += replacements

    if changed_resources:
        descriptor, temporary_name = tempfile.mkstemp(
            prefix=pak_path.name + ".", suffix=".tmp", dir=pak_path.parent
        )
        os.close(descriptor)
        try:
            write_data_pack(contents.resources, pathlib.Path(temporary_name), contents.encoding)
            os.replace(temporary_name, pak_path)
        finally:
            if os.path.exists(temporary_name):
                os.unlink(temporary_name)
    return changed_resources, replacement_count


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("runtime", type=pathlib.Path)
    arguments = parser.parse_args()

    pak_count = 0
    changed_paks = 0
    changed_resources = 0
    replacement_count = 0
    for pak_path in sorted(arguments.runtime.rglob("*.pak")):
        pak_count += 1
        resources, replacements = rebrand_pak(pak_path)
        if resources:
            changed_paks += 1
            changed_resources += resources
            replacement_count += replacements

    print(
        f"Processed {pak_count} packs; branded {replacement_count} occurrences "
        f"in {changed_resources} resources across {changed_paks} packs."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
