#!/usr/bin/env python3
"""Stream frames from a V4L2 device and tally per-buffer flags.

Written to answer: does the HOST see the same errored buffers that Waydroid's
external camera HAL reports as

    ExtCamDevSsn@3.4: dequeueV4l2FrameLocked: v4l2 buf error! buf flag 0x12040

0x12040 decodes as TSTAMP_SRC_SOE | TIMESTAMP_MONOTONIC | ERROR. If the same
ERROR-flagged buffers arrive here, the fault is in USB/uvcvideo and has nothing
to do with Waydroid or the HAL.

uvcvideo's `nodrop` parameter decides what happens to an incomplete frame:
delivered with V4L2_BUF_FLAG_ERROR set (nodrop=1) or silently dropped
(nodrop=0). Either way the frame is damaged; nodrop only chooses who notices.

Usage: v4l2-stream-stats.py [device] [width] [height] [MJPG|YUYV] [nframes]
"""
import ctypes, fcntl, mmap, select, sys, time

VIDIOC_S_FMT = 0xC0D05605
VIDIOC_REQBUFS = 0xC0145608
VIDIOC_QUERYBUF = 0xC0585609
VIDIOC_QBUF = 0xC058560F
VIDIOC_DQBUF = 0xC0585611
VIDIOC_STREAMON = 0x40045612
VIDIOC_STREAMOFF = 0x40045613
VIDIOC_G_PARM = 0xC0CC5615
CAPTURE, MMAP = 1, 1

BUF_FLAGS = [
    (0x00000001, "MAPPED"), (0x00000002, "QUEUED"), (0x00000004, "DONE"),
    (0x00000008, "KEYFRAME"), (0x00000010, "PFRAME"), (0x00000020, "BFRAME"),
    (0x00000040, "ERROR"), (0x00000080, "IN_REQUEST"), (0x00000100, "TIMECODE"),
    (0x00000400, "PREPARED"), (0x00000800, "NO_CACHE_INVALIDATE"),
    (0x00001000, "NO_CACHE_CLEAN"), (0x00100000, "LAST"), (0x00200000, "REQUEST_FD"),
]
TS_TYPE = {0x0000: "TS_UNKNOWN", 0x2000: "TS_MONOTONIC", 0x4000: "TS_COPY"}
TS_SRC = {0x00000: "SRC_EOF", 0x10000: "SRC_SOE", 0x20000: "SRC_SOE_TRIG"}
ERROR = 0x40


def decode_flags(f):
    out = [n for bit, n in BUF_FLAGS if f & bit]
    out.append(TS_TYPE.get(f & 0xE000, f"TS_?{f & 0xE000:x}"))
    out.append(TS_SRC.get(f & 0x70000, f"SRC_?{f & 0x70000:x}"))
    return "|".join(out)


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


class CaptureParm(ctypes.Structure):
    _fields_ = [("capability", ctypes.c_uint32), ("capturemode", ctypes.c_uint32),
                ("numerator", ctypes.c_uint32), ("denominator", ctypes.c_uint32),
                ("extendedmode", ctypes.c_uint32), ("readbuffers", ctypes.c_uint32),
                ("reserved", ctypes.c_uint32 * 4)]


class StreamParm(ctypes.Structure):
    _fields_ = [("type", ctypes.c_uint32), ("parm", CaptureParm),
                ("pad", ctypes.c_uint8 * (200 - ctypes.sizeof(CaptureParm)))]


def main():
    sys.stdout.reconfigure(line_buffering=True)
    dev = sys.argv[1] if len(sys.argv) > 1 else "/dev/video0"
    w = int(sys.argv[2]) if len(sys.argv) > 2 else 1280
    h = int(sys.argv[3]) if len(sys.argv) > 3 else 720
    pf = sys.argv[4] if len(sys.argv) > 4 else "MJPG"
    n = int(sys.argv[5]) if len(sys.argv) > 5 else 300

    fd = open(dev, "rb+", buffering=0)
    f = Format(type=CAPTURE)
    f.pix.width, f.pix.height = w, h
    f.pix.pixelformat, f.pix.field = fourcc_of(pf), 1
    fcntl.ioctl(fd, VIDIOC_S_FMT, f)
    print(f"negotiated: {f.pix.width}x{f.pix.height} {pf} sizeimage={f.pix.sizeimage}")

    p = StreamParm(type=CAPTURE)
    try:
        fcntl.ioctl(fd, VIDIOC_G_PARM, p)
        if p.parm.numerator:
            print(f"frame interval: {p.parm.numerator}/{p.parm.denominator} "
                  f"= {p.parm.denominator / p.parm.numerator:.1f} fps")
    except OSError:
        pass

    NBUF = 4
    fcntl.ioctl(fd, VIDIOC_REQBUFS, ReqBufs(count=NBUF, type=CAPTURE, memory=MMAP))
    maps = []
    for i in range(NBUF):
        b = Buffer(index=i, type=CAPTURE, memory=MMAP)
        fcntl.ioctl(fd, VIDIOC_QUERYBUF, b)
        maps.append(mmap.mmap(fd.fileno(), b.length, mmap.MAP_SHARED,
                              mmap.PROT_READ, offset=b.offset))
        fcntl.ioctl(fd, VIDIOC_QBUF, b)

    fcntl.ioctl(fd, VIDIOC_STREAMON, ctypes.c_int(CAPTURE))
    errs = short = timeouts = 0
    sizes, seqs, flagset = [], [], {}
    t0 = time.monotonic()
    try:
        for i in range(n):
            if not select.select([fd], [], [], 5.0)[0]:
                timeouts += 1
                print(f"  [{i}] TIMEOUT")
                continue
            b = Buffer(type=CAPTURE, memory=MMAP)
            fcntl.ioctl(fd, VIDIOC_DQBUF, b)
            flagset[b.flags] = flagset.get(b.flags, 0) + 1
            sizes.append(b.bytesused)
            seqs.append(b.sequence)
            if b.flags & ERROR:
                errs += 1
                print(f"  [{i}] seq={b.sequence} bytes={b.bytesused} "
                      f"flags=0x{b.flags:x} {decode_flags(b.flags)}")
            if pf == "MJPG" and b.bytesused and \
               bytes(maps[b.index][b.bytesused - 2:b.bytesused]) != b"\xff\xd9":
                short += 1
            fcntl.ioctl(fd, VIDIOC_QBUF, b)
    finally:
        fcntl.ioctl(fd, VIDIOC_STREAMOFF, ctypes.c_int(CAPTURE))
    dt = time.monotonic() - t0

    got = len(sizes)
    gaps = sum(seqs[i + 1] - seqs[i] - 1 for i in range(len(seqs) - 1)) if got > 1 else 0
    print(f"\n=== {got} frames in {dt:.1f}s = {got / dt:.1f} fps effective ===")
    print(f"  ERROR-flagged      : {errs}  ({100.0 * errs / got if got else 0:.1f}%)")
    print(f"  sequence gaps      : {gaps}  (frames the driver dropped outright)")
    print(f"  select() timeouts  : {timeouts}")
    if pf == "MJPG":
        print(f"  missing EOI (ffd9) : {short}  (truncated JPEG payloads)")
    if sizes:
        print(f"  bytesused          : min={min(sizes)} max={max(sizes)} "
              f"avg={sum(sizes) // len(sizes)}")
    print("  flag histogram:")
    for fl, c in sorted(flagset.items(), key=lambda kv: -kv[1]):
        print(f"    0x{fl:06x} x{c:<5} {decode_flags(fl)}")


if __name__ == "__main__":
    main()
