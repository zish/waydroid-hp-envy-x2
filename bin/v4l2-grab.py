#!/usr/bin/env python3
"""Capture one raw frame from a V4L2 device and report its JPEG marker structure.

Written to answer a specific question: does this camera's MJPEG stream carry its own
Huffman tables (DHT, marker 0xFFC4)? UVC cameras are permitted to omit them, and
decoders that do not substitute the standard tables then fail. Android's external
camera HAL decodes via libyuv MJPGToI420, which is one such decoder.

Usage: v4l2-grab.py [device] [width] [height] [out.jpg]
"""
import ctypes, fcntl, mmap, select, sys

VIDIOC_S_FMT = 0xC0D05605
VIDIOC_REQBUFS = 0xC0145608
VIDIOC_QUERYBUF = 0xC0585609
VIDIOC_QBUF = 0xC058560F
VIDIOC_DQBUF = 0xC0585611
VIDIOC_STREAMON = 0x40045612
VIDIOC_STREAMOFF = 0x40045613
CAPTURE, MMAP = 1, 1


def fourcc_of(s):
    return sum(ord(c) << (8 * i) for i, c in enumerate(s))


class PixFormat(ctypes.Structure):
    _fields_ = [("width", ctypes.c_uint32), ("height", ctypes.c_uint32),
                ("pixelformat", ctypes.c_uint32), ("field", ctypes.c_uint32),
                ("bytesperline", ctypes.c_uint32), ("sizeimage", ctypes.c_uint32),
                ("colorspace", ctypes.c_uint32), ("priv", ctypes.c_uint32)]


class Format(ctypes.Structure):
    _fields_ = [("type", ctypes.c_uint32), ("_pad0", ctypes.c_uint32),
                ("pix", PixFormat),
                ("pad", ctypes.c_uint8 * (200 - ctypes.sizeof(PixFormat)))]


class ReqBufs(ctypes.Structure):
    _fields_ = [("count", ctypes.c_uint32), ("type", ctypes.c_uint32),
                ("memory", ctypes.c_uint32), ("capabilities", ctypes.c_uint32),
                ("flags", ctypes.c_uint8), ("reserved", ctypes.c_uint8 * 3)]


class Buffer(ctypes.Structure):
    _fields_ = [("index", ctypes.c_uint32), ("type", ctypes.c_uint32),
                ("bytesused", ctypes.c_uint32), ("flags", ctypes.c_uint32),
                ("field", ctypes.c_uint32), ("_pad", ctypes.c_uint32),
                ("tv_sec", ctypes.c_int64), ("tv_usec", ctypes.c_int64),
                ("timecode", ctypes.c_uint8 * 16), ("sequence", ctypes.c_uint32),
                ("memory", ctypes.c_uint32), ("offset", ctypes.c_uint64),
                ("length", ctypes.c_uint32), ("reserved2", ctypes.c_uint32),
                ("request_fd", ctypes.c_int32), ("_pad2", ctypes.c_uint32)]


JPEG_MARKERS = {0xD8: "SOI", 0xC0: "SOF0 (baseline)", 0xC2: "SOF2 (progressive)",
                0xC4: "DHT (Huffman tables)", 0xDB: "DQT (quant tables)",
                0xDD: "DRI", 0xDA: "SOS (start of scan)", 0xD9: "EOI",
                0xE0: "APP0/JFIF", 0xE1: "APP1", 0xFE: "COM"}


def describe_jpeg(data):
    print(f"\n  size: {len(data)} bytes   first bytes: {data[:4].hex()}")
    if data[:2] != b"\xff\xd8":
        print("  !! does not start with SOI (ffd8) - not a JPEG")
        return
    seen, i = [], 2
    while i < len(data) - 1:
        if data[i] != 0xFF:
            i += 1
            continue
        m = data[i + 1]
        if m in (0xD8, 0xD9, 0x00, 0xFF):
            i += 2
            continue
        name = JPEG_MARKERS.get(m, f"0x{m:02X}")
        seen.append((m, name))
        if m == 0xDA:
            break
        if i + 3 >= len(data):
            break
        i += 2 + int.from_bytes(data[i + 2:i + 4], "big")
    for m, name in seen:
        print(f"    ff{m:02x}  {name}")
    has_dht = any(m == 0xC4 for m, _ in seen)
    print(f"\n  DHT present: {'YES' if has_dht else 'NO'}")
    if not has_dht:
        print("  -> Frames omit Huffman tables. Decoders that do not substitute the")
        print("     standard tables (e.g. libyuv MJPGToI420) will FAIL on this stream.")


def main():
    dev = sys.argv[1] if len(sys.argv) > 1 else "/dev/video0"
    w = int(sys.argv[2]) if len(sys.argv) > 2 else 1280
    h = int(sys.argv[3]) if len(sys.argv) > 3 else 720
    out = sys.argv[4] if len(sys.argv) > 4 else "/tmp/frame.jpg"

    fd = open(dev, "rb+", buffering=0)
    f = Format(type=CAPTURE)
    f.pix.width, f.pix.height = w, h
    f.pix.pixelformat, f.pix.field = fourcc_of("MJPG"), 1
    fcntl.ioctl(fd, VIDIOC_S_FMT, f)
    print(f"negotiated: {f.pix.width}x{f.pix.height} sizeimage={f.pix.sizeimage}")

    fcntl.ioctl(fd, VIDIOC_REQBUFS, ReqBufs(count=4, type=CAPTURE, memory=MMAP))
    maps = []
    for i in range(4):
        b = Buffer(index=i, type=CAPTURE, memory=MMAP)
        fcntl.ioctl(fd, VIDIOC_QUERYBUF, b)
        maps.append(mmap.mmap(fd.fileno(), b.length, mmap.MAP_SHARED,
                              mmap.PROT_READ, offset=b.offset))
        fcntl.ioctl(fd, VIDIOC_QBUF, b)

    fcntl.ioctl(fd, VIDIOC_STREAMON, ctypes.c_int(CAPTURE))
    data = None
    try:
        # Discard the first few frames; some webcams emit malformed leading frames.
        for n in range(5):
            if not select.select([fd], [], [], 5.0)[0]:
                print("  timeout waiting for frame")
                break
            b = Buffer(type=CAPTURE, memory=MMAP)
            fcntl.ioctl(fd, VIDIOC_DQBUF, b)
            data = bytes(maps[b.index][:b.bytesused])
            print(f"  frame {n}: {b.bytesused} bytes")
            fcntl.ioctl(fd, VIDIOC_QBUF, b)
    finally:
        fcntl.ioctl(fd, VIDIOC_STREAMOFF, ctypes.c_int(CAPTURE))

    if data:
        open(out, "wb").write(data)
        print(f"\nwrote {out}")
        describe_jpeg(data)


if __name__ == "__main__":
    main()
