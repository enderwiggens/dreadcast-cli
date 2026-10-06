#!/usr/bin/env python3
"""Generate Sources/DreadcastKit/BasemapData.swift from Natural Earth 1:50m data.

Natural Earth is public domain (https://www.naturalearthdata.com/about/terms-of-use/).
The output is a compact binary, base64-encoded into Swift so `dread` ships as a
single executable with no resource bundle.

Usage:
    scripts/build-basemap.py [--source DIR]

Without --source the GeoJSON files are downloaded from the Natural Earth
GitHub mirror into a temporary directory.

Format (little-endian varints, zigzag for signed values, coordinates in 0.01°):
    "DCB1"
    u8 layer count
    per layer: u8 kind, varint ring count,
               per ring: varint point count, then zigzag deltas lon, lat
    varint city count
    per city: zigzag lon, zigzag lat (absolute), u8 rank, u8 name length, UTF-8 name
Layer kinds: 1 land (polygon rings), 2 lakes (polygon rings),
             3 country borders (lines), 4 state and province borders (lines).
"""
import argparse
import base64
import json
import os
import sys
import tempfile
import urllib.request

BASE = "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/"
FILES = {
    "land": "ne_50m_land.geojson",
    "lakes": "ne_50m_lakes.geojson",
    "countries": "ne_50m_admin_0_boundary_lines_land.geojson",
    "states": "ne_50m_admin_1_states_provinces_lines.geojson",
    "cities": "ne_50m_populated_places_simple.geojson",
}
SCALE = 100          # 0.01 degree quantization, about 1.1 km
TOLERANCE = 0.008    # Douglas-Peucker tolerance in degrees


def load(source, name):
    path = os.path.join(source, FILES[name])
    if not os.path.exists(path):
        print(f"downloading {FILES[name]}", file=sys.stderr)
        urllib.request.urlretrieve(BASE + FILES[name], path)
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def simplify(points, tolerance):
    if len(points) < 3:
        return points
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        start, end = stack.pop()
        ax, ay = points[start]
        bx, by = points[end]
        dx, dy = bx - ax, by - ay
        length = (dx * dx + dy * dy) ** 0.5
        best, index = -1.0, -1
        for i in range(start + 1, end):
            px, py = points[i]
            if length == 0:
                distance = ((px - ax) ** 2 + (py - ay) ** 2) ** 0.5
            else:
                distance = abs(dy * px - dx * py + bx * ay - by * ax) / length
            if distance > best:
                best, index = distance, i
        if best > tolerance and index > 0:
            keep[index] = True
            stack.append((start, index))
            stack.append((index, end))
    return [p for p, k in zip(points, keep) if k]


def quantize(points):
    result = []
    for lon, lat in points:
        q = (round(lon * SCALE), round(lat * SCALE))
        if not result or result[-1] != q:
            result.append(q)
    return result


def rings_from(geometry, polygons):
    kind = geometry["type"]
    coords = geometry["coordinates"]
    if polygons:
        if kind == "Polygon":
            return list(coords)
        if kind == "MultiPolygon":
            return [ring for polygon in coords for ring in polygon]
    else:
        if kind == "LineString":
            return [coords]
        if kind == "MultiLineString":
            return list(coords)
    return []


def varint(value, out):
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return


def zigzag(value):
    return (value << 1) ^ (value >> 63)


def encode_layer(kind, rings, polygons, out):
    cleaned = []
    minimum = 4 if polygons else 2
    for ring in rings:
        points = quantize(simplify([(p[0], p[1]) for p in ring], TOLERANCE))
        if len(points) >= minimum:
            cleaned.append(points)
    out.append(kind)
    varint(len(cleaned), out)
    total = 0
    for points in cleaned:
        varint(len(points), out)
        previous = (0, 0)
        for point in points:
            varint(zigzag(point[0] - previous[0]), out)
            varint(zigzag(point[1] - previous[1]), out)
            previous = point
        total += len(points)
    return len(cleaned), total


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", help="directory containing the Natural Earth GeoJSON files")
    parser.add_argument("--output", default=os.path.join(os.path.dirname(__file__), "..", "Sources", "DreadcastKit", "BasemapData.swift"))
    args = parser.parse_args()
    source = args.source or tempfile.mkdtemp(prefix="dreadcast-ne-")

    out = bytearray(b"DCB1")
    layers = [
        (1, "land", True),
        (2, "lakes", True),
        (3, "countries", False),
        (4, "states", False),
    ]
    out.append(len(layers))
    for kind, name, polygons in layers:
        data = load(source, name)
        rings = [ring for feature in data["features"] if feature.get("geometry")
                 for ring in rings_from(feature["geometry"], polygons)]
        count, total = encode_layer(kind, rings, polygons, out)
        print(f"{name}: {count} rings, {total} points", file=sys.stderr)

    cities = []
    for feature in load(source, "cities")["features"]:
        props = feature["properties"]
        lon, lat = feature["geometry"]["coordinates"][:2]
        name = (props.get("name") or "").strip()
        if not name:
            continue
        rank = int(props.get("scalerank") if props.get("scalerank") is not None else 10)
        encoded = name.encode("utf-8")[:255]
        cities.append((rank, -(props.get("pop_max") or 0), round(lon * SCALE), round(lat * SCALE), encoded))
    cities.sort()
    varint(len(cities), out)
    for rank, _, lon, lat, encoded in cities:
        varint(zigzag(lon), out)
        varint(zigzag(lat), out)
        out.append(max(0, min(255, rank)))
        out.append(len(encoded))
        out.extend(encoded)
    print(f"cities: {len(cities)}", file=sys.stderr)
    print(f"binary: {len(out)} bytes", file=sys.stderr)

    encoded = base64.b64encode(bytes(out)).decode("ascii")
    lines = [encoded[i:i + 120] for i in range(0, len(encoded), 120)]
    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write("// Generated by scripts/build-basemap.py from Natural Earth 1:50m data (public domain).\n")
        handle.write("// Do not edit by hand.\n\n")
        handle.write("enum BasemapData {\n")
        handle.write("    static let base64 = \"\"\"\n")
        for line in lines:
            handle.write(line + "\n")
        handle.write("\"\"\"\n}\n")
    print(f"wrote {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
