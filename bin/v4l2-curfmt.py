#!/usr/bin/env python3
"""Report the pixel format currently negotiated on a V4L2 device (VIDIOC_G_FMT).

Safe to run while another process is streaming: G_FMT is a query, and opening a
V4L2 node a second time does not disturb the active stream.
"""
import ctypes, fcntl, sys

VIDIOC_G_FMT = 0xC0D05604
V4L2_BUF_TYPE_VIDEO_CAPTURE = 1


class PixFormat(ctypes.Structure):
    _fields_ = [("width", ctypes.c_uint32), ("height", ctypes.c_uint32),
                ("pixelformat", ctypes.c_uint32), ("field", ctypes.c_uint32),
                ("bytesperline", ctypes.c_uint32), ("sizeimage", ctypes.c_uint32),
                ("colorspace", ctypes.c_uint32), ("priv", ctypes.c_uint32)]


class Format(ctypes.Structure):
    # struct v4l2_format is 208 bytes: __u32 type, 4 bytes of padding, then a
    # 200-byte union starting at offset 8.
    _fields_ = [("type", ctypes.c_uint32), ("_pad0", ctypes.c_uint32),
                ("pix", PixFormat),
                ("pad", ctypes.c_uint8 * (200 - ctypes.sizeof(PixFormat)))]


def fourcc(v):
    return "".join(chr((v >> (8 * i)) & 0xFF) for i in range(4))


path = sys.argv[1] if len(sys.argv) > 1 else "/dev/video0"
fd = open(path, "rb", buffering=0)
f = Format(type=V4L2_BUF_TYPE_VIDEO_CAPTURE)
fcntl.ioctl(fd, VIDIOC_G_FMT, f)
p = f.pix
print(f"{path}: {fourcc(p.pixelformat)}  {p.width}x{p.height}  "
      f"bytesperline={p.bytesperline}  sizeimage={p.sizeimage}")
print(f"  (w*h*2 = {p.width * p.height * 2})")
