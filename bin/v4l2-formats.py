#!/usr/bin/env python3
"""Enumerate V4L2 formats/resolutions/framerates for a capture device.

Exists because v4l2-ctl (v4l-utils) is not installed on bigtab01, and layering a
package onto an rpm-ostree host requires a reboot. Pure ioctl, stdlib only.
"""
import ctypes, fcntl, sys

VIDIOC_ENUM_FMT = 0xC0405602
VIDIOC_ENUM_FRAMESIZES = 0xC02C564A
VIDIOC_ENUM_FRAMEINTERVALS = 0xC034564B
V4L2_BUF_TYPE_VIDEO_CAPTURE = 1


class FmtDesc(ctypes.Structure):
    _fields_ = [("index", ctypes.c_uint32), ("type", ctypes.c_uint32),
                ("flags", ctypes.c_uint32), ("description", ctypes.c_char * 32),
                ("pixelformat", ctypes.c_uint32), ("reserved", ctypes.c_uint32 * 4)]


class FrmSize(ctypes.Structure):
    _fields_ = [("index", ctypes.c_uint32), ("pixel_format", ctypes.c_uint32),
                ("type", ctypes.c_uint32), ("width", ctypes.c_uint32),
                ("height", ctypes.c_uint32), ("pad", ctypes.c_uint32 * 6),
                ("reserved", ctypes.c_uint32 * 2)]


class FrmIval(ctypes.Structure):
    _fields_ = [("index", ctypes.c_uint32), ("pixel_format", ctypes.c_uint32),
                ("width", ctypes.c_uint32), ("height", ctypes.c_uint32),
                ("type", ctypes.c_uint32), ("numerator", ctypes.c_uint32),
                ("denominator", ctypes.c_uint32), ("pad", ctypes.c_uint32 * 4),
                ("reserved", ctypes.c_uint32 * 2)]


def fourcc(v):
    return "".join(chr((v >> (8 * i)) & 0xFF) for i in range(4))


def main(path):
    fd = open(path, "rb", buffering=0)
    for i in range(64):
        f = FmtDesc(index=i, type=V4L2_BUF_TYPE_VIDEO_CAPTURE)
        try:
            fcntl.ioctl(fd, VIDIOC_ENUM_FMT, f)
        except OSError:
            break
        print(f"\n[{fourcc(f.pixelformat)}] {f.description.decode(errors='replace')}"
              f"{'  (compressed)' if f.flags & 1 else ''}")
        for j in range(128):
            s = FrmSize(index=j, pixel_format=f.pixelformat)
            try:
                fcntl.ioctl(fd, VIDIOC_ENUM_FRAMESIZES, s)
            except OSError:
                break
            if s.type != 1:          # only discrete sizes
                print(f"    (non-discrete frame sizes, type={s.type})")
                break
            rates = []
            for k in range(64):
                iv = FrmIval(index=k, pixel_format=f.pixelformat,
                             width=s.width, height=s.height)
                try:
                    fcntl.ioctl(fd, VIDIOC_ENUM_FRAMEINTERVALS, iv)
                except OSError:
                    break
                if iv.type != 1 or iv.numerator == 0:
                    break
                rates.append(f"{iv.denominator / iv.numerator:g}")
            print(f"    {s.width}x{s.height}" + (f"  @ {', '.join(rates)} fps" if rates else ""))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "/dev/video0")
