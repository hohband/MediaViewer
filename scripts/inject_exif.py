#!/usr/bin/env python3
"""把指定的 EXIF / GPS 写入 JPEG，用于端到端校验元数据读取链路。

这里是刻意手写 TIFF/EXIF 字节，而不是调用 ImageIO 回写：
如果写和读用同一套实现，测试就会“自证”，真实相机文件里的字段名写错了也发现不了。
"""

import argparse
import struct
import sys
from fractions import Fraction
from pathlib import Path

BYTE, ASCII, SHORT, LONG, RATIONAL, UNDEFINED = 1, 2, 3, 4, 5, 7

TAG_MAKE = 0x010F
TAG_MODEL = 0x0110
TAG_ORIENTATION = 0x0112
TAG_SOFTWARE = 0x0131
TAG_DATETIME = 0x0132
TAG_EXIF_IFD = 0x8769
TAG_GPS_IFD = 0x8825

TAG_EXPOSURE_TIME = 0x829A
TAG_FNUMBER = 0x829D
TAG_ISO = 0x8827
TAG_EXIF_VERSION = 0x9000
TAG_DATETIME_ORIGINAL = 0x9003
TAG_DATETIME_DIGITIZED = 0x9004
TAG_FOCAL_LENGTH = 0x920A
TAG_PIXEL_X_DIMENSION = 0xA002
TAG_PIXEL_Y_DIMENSION = 0xA003
TAG_LENS_MODEL = 0xA434

TAG_GPS_LAT_REF = 0x0001
TAG_GPS_LAT = 0x0002
TAG_GPS_LON_REF = 0x0003
TAG_GPS_LON = 0x0004
TAG_GPS_ALT_REF = 0x0005
TAG_GPS_ALT = 0x0006
TAG_GPS_TIME_STAMP = 0x0007
TAG_GPS_DATE_STAMP = 0x001D


def entry_ascii(tag, text):
    payload = text.encode("ascii") + b"\x00"
    return (tag, ASCII, len(payload), payload)


def entry_undefined(tag, payload):
    return (tag, UNDEFINED, len(payload), payload)


def entry_short(tag, *values):
    payload = b"".join(struct.pack(">H", v) for v in values)
    return (tag, SHORT, len(values), payload)


def entry_long(tag, *values):
    payload = b"".join(struct.pack(">I", v) for v in values)
    return (tag, LONG, len(values), payload)


def entry_rational(tag, *pairs):
    payload = b"".join(struct.pack(">II", int(n), int(d)) for n, d in pairs)
    return (tag, RATIONAL, len(pairs), payload)


def ifd_size(entry_count):
    return 2 + 12 * entry_count + 4


def data_size(entries):
    return sum(len(entry[3]) for entry in entries if len(entry[3]) > 4)


def serialize_ifd(entries, data_offset):
    """返回 (IFD 字节, 该 IFD 的值数据字节)；值数据紧跟在所有 IFD 之后。"""
    entries = sorted(entries, key=lambda entry: entry[0])
    ifd = struct.pack(">H", len(entries))
    data = b""
    for tag, value_type, count, payload in entries:
        if len(payload) <= 4:
            value_field = payload + b"\x00" * (4 - len(payload))
        else:
            value_field = struct.pack(">I", data_offset + len(data))
            data += payload
        ifd += struct.pack(">HHI", tag, value_type, count) + value_field
    ifd += struct.pack(">I", 0)
    return ifd, data


def dms(value):
    value = abs(value)
    degrees = int(value)
    minutes = int((value - degrees) * 60)
    seconds = (value - degrees - minutes / 60) * 3600
    return [(degrees, 1), (minutes, 1), (int(round(seconds * 100)), 100)]


def build_tiff(args):
    ifd0 = []
    if args.make:
        ifd0.append(entry_ascii(TAG_MAKE, args.make))
    if args.model:
        ifd0.append(entry_ascii(TAG_MODEL, args.model))
    if args.software:
        ifd0.append(entry_ascii(TAG_SOFTWARE, args.software))
    if args.datetime:
        ifd0.append(entry_ascii(TAG_DATETIME, args.datetime))
    ifd0.append(entry_short(TAG_ORIENTATION, 1))

    exif = []
    if args.exposure:
        fraction = Fraction(args.exposure).limit_denominator(100000)
        exif.append(entry_rational(TAG_EXPOSURE_TIME, (fraction.numerator, fraction.denominator)))
    if args.fnumber:
        fraction = Fraction(args.fnumber).limit_denominator(1000)
        exif.append(entry_rational(TAG_FNUMBER, (fraction.numerator, fraction.denominator)))
    if args.iso:
        exif.append(entry_short(TAG_ISO, args.iso))
    if args.focal:
        exif.append(entry_rational(TAG_FOCAL_LENGTH, (int(args.focal), 1)))
    if args.lens:
        exif.append(entry_ascii(TAG_LENS_MODEL, args.lens))
    if args.datetime:
        exif.append(entry_ascii(TAG_DATETIME_ORIGINAL, args.datetime))
        exif.append(entry_ascii(TAG_DATETIME_DIGITIZED, args.datetime))
    exif.append(entry_undefined(TAG_EXIF_VERSION, b"0232"))
    if args.width and args.height:
        exif.append(entry_long(TAG_PIXEL_X_DIMENSION, args.width))
        exif.append(entry_long(TAG_PIXEL_Y_DIMENSION, args.height))

    gps = []
    if args.gps_lat is not None:
        gps.append(entry_ascii(TAG_GPS_LAT_REF, "N" if args.gps_lat >= 0 else "S"))
        gps.append(entry_rational(TAG_GPS_LAT, *dms(args.gps_lat)))
    if args.gps_lon is not None:
        gps.append(entry_ascii(TAG_GPS_LON_REF, "E" if args.gps_lon >= 0 else "W"))
        gps.append(entry_rational(TAG_GPS_LON, *dms(args.gps_lon)))
    if args.gps_alt is not None:
        gps.append((TAG_GPS_ALT_REF, BYTE, 1, bytes([0 if args.gps_alt >= 0 else 1])))
        gps.append(entry_rational(TAG_GPS_ALT, (int(round(abs(args.gps_alt) * 100)), 100)))
    if gps:
        gps.append(entry_ascii(TAG_GPS_DATE_STAMP, "2024:05:06"))
        gps.append(entry_rational(TAG_GPS_TIME_STAMP, (7, 1), (8, 1), (9, 1)))

    if exif:
        ifd0.append(entry_long(TAG_EXIF_IFD, 0))  # 占位，下面回填
    if gps:
        ifd0.append(entry_long(TAG_GPS_IFD, 0))

    ifd0_offset = 8
    data0_offset = ifd0_offset + ifd_size(len(ifd0))
    exif_offset = data0_offset + data_size(ifd0)
    exif_data_offset = exif_offset + ifd_size(len(exif))
    gps_offset = exif_data_offset + data_size(exif)
    gps_data_offset = gps_offset + ifd_size(len(gps))

    for index, entry in enumerate(ifd0):
        if entry[0] == TAG_EXIF_IFD:
            ifd0[index] = entry_long(TAG_EXIF_IFD, exif_offset)
        elif entry[0] == TAG_GPS_IFD:
            ifd0[index] = entry_long(TAG_GPS_IFD, gps_offset)

    header = b"MM\x00\x2a" + struct.pack(">I", ifd0_offset)
    parts = [header]

    ifd0_bytes, ifd0_data = serialize_ifd(ifd0, data0_offset)
    parts += [ifd0_bytes, ifd0_data]

    if exif:
        exif_bytes, exif_data = serialize_ifd(exif, exif_data_offset)
        parts += [exif_bytes, exif_data]

    if gps:
        gps_bytes, gps_data = serialize_ifd(gps, gps_data_offset)
        parts += [gps_bytes, gps_data]

    return b"".join(parts)


def strip_existing_exif(data):
    """去掉 JPEG 里已有的 APP1/EXIF 段，返回 SOI 之后的内容也保持原样。"""
    if not data.startswith(b"\xff\xd8"):
        raise ValueError("不是 JPEG 文件（缺少 SOI）")

    output = bytearray(data[:2])
    index = 2
    while index + 1 < len(data):
        if data[index] != 0xFF:
            break
        marker = data[index + 1]
        if marker == 0xD8:
            index += 2
            continue
        if marker == 0xDA:  # SOS：后面是压缩数据，直接照抄
            output += data[index:]
            return bytes(output)
        if index + 4 > len(data):
            break
        length = struct.unpack(">H", data[index + 2:index + 4])[0]
        segment = data[index:index + 2 + length]
        if marker == 0xE1 and segment[4:10] == b"Exif\x00\x00":
            index += 2 + length
            continue
        output += segment
        index += 2 + length

    output += data[index:]
    return bytes(output)


def main():
    parser = argparse.ArgumentParser(description="给 JPEG 写入 EXIF/GPS（手写 TIFF 字节）")
    parser.add_argument("path", type=Path)
    parser.add_argument("--make")
    parser.add_argument("--model")
    parser.add_argument("--software")
    parser.add_argument("--lens")
    parser.add_argument("--datetime", help="EXIF 时间格式：2024:05:06 07:08:09")
    parser.add_argument("--fnumber", type=float)
    parser.add_argument("--exposure", type=float, help="快门时间，单位秒，例如 0.004")
    parser.add_argument("--iso", type=int)
    parser.add_argument("--focal", type=float)
    parser.add_argument("--width", type=int)
    parser.add_argument("--height", type=int)
    parser.add_argument("--gps-lat", type=float)
    parser.add_argument("--gps-lon", type=float)
    parser.add_argument("--gps-alt", type=float)
    args = parser.parse_args()

    if not args.path.is_file():
        print(f"文件不存在：{args.path}", file=sys.stderr)
        return 1

    tiff = build_tiff(args)
    payload = b"Exif\x00\x00" + tiff
    app1 = b"\xff\xe1" + struct.pack(">H", len(payload) + 2) + payload

    original = args.path.read_bytes()
    stripped = strip_existing_exif(original)
    args.path.write_bytes(stripped[:2] + app1 + stripped[2:])
    print(f"已写入 EXIF：{args.path}（APP1 {len(app1)} 字节）")
    return 0


if __name__ == "__main__":
    sys.exit(main())