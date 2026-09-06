#!/usr/bin/env python3
"""Decode a HID report descriptor, with HID Sensor usage page annotations.

Written for bigtab01 to answer one question the kernel will not: what Unit and
Unit Exponent does the ITE8350 sensor hub declare for each sensor's data
fields?  `in_magn_scale` reads back as an unhelpful 1.000000000, which is the
kernel's *failure* value -- hid_sensor_format_scale() returns -EINVAL and
leaves the caller's 1/0 untouched when the declared unit is not in its
conversion table.  The descriptor is the ground truth.

stdlib only: bigtab01 is an immutable host and the dev box has no pip.

Usage:
    hid-decode.py FILE.rd            # full item dump
    hid-decode.py FILE.rd --fields   # one line per data field (the useful mode)
"""

import sys

# --- HID item tables ------------------------------------------------------

MAIN_TAGS = {8: "Input", 9: "Output", 11: "Feature",
             10: "Collection", 12: "End Collection"}
GLOBAL_TAGS = {0: "Usage Page", 1: "Logical Minimum", 2: "Logical Maximum",
               3: "Physical Minimum", 4: "Physical Maximum",
               5: "Unit Exponent", 6: "Unit", 7: "Report Size",
               8: "Report ID", 9: "Report Count", 10: "Push", 11: "Pop"}
LOCAL_TAGS = {0: "Usage", 1: "Usage Minimum", 2: "Usage Maximum",
              3: "Designator Index", 4: "Designator Minimum",
              5: "Designator Maximum", 7: "String Index",
              8: "String Minimum", 9: "String Maximum", 10: "Delimiter"}
COLLECTIONS = {0: "Physical", 1: "Application", 2: "Logical", 3: "Report",
               4: "Named Array", 5: "Usage Switch", 6: "Usage Modifier"}

# HID Sensor usage page (0x20) -- the sensor *types* we care about.
SENSOR_TYPES = {
    0x0073: "Motion: Accelerometer 3D",
    0x0076: "Motion: Gyrometer 3D",
    0x0083: "Orientation: Compass 3D",
    0x0086: "Orientation: Inclinometer 3D",
    0x008A: "Orientation: Device Orientation",
    0x0041: "Environmental: Ambient Light",
    0x0001: "Sensor (generic collection)",
}

# HID Sensor data fields, from the HID Sensor Usages spec.
DATA_FIELDS = {
    0x0451: "Motion State",
    0x0452: "Data Field: Acceleration",
    0x0453: "Acceleration X Axis", 0x0454: "Acceleration Y Axis",
    0x0455: "Acceleration Z Axis",
    0x0456: "Data Field: Angular Velocity",
    0x0457: "Angular Velocity X Axis", 0x0458: "Angular Velocity Y Axis",
    0x0459: "Angular Velocity Z Axis",
    # Orientation data fields.  IDs below are as observed in the ITE8350
    # descriptor and cross-checked against the IIO channels the kernel
    # creates from them.
    0x0475: "Compass Heading, tilt-compensated",   # -> in_rot_from_north_...
    0x047F: "Inclinometer X Axis", 0x0480: "Inclinometer Y Axis",
    0x0481: "Inclinometer Z Axis",
    0x0482: "Rotation Matrix",                     # 9 values; IIO ignores it
    0x0483: "Quaternion",                          # -> in_rot_quaternion_raw
    0x0485: "Magnetic Flux X Axis", 0x0486: "Magnetic Flux Y Axis",
    0x0487: "Magnetic Flux Z Axis",
    0x0488: "Magnetometer Accuracy",
    0x04D1: "Illuminance",
    0x030E: "Property: Change Sensitivity (absolute)",
    0x030F: "Property: Report Interval",
    0x0316: "Property: Reporting State",
    0x0319: "Property: Power State",
    0x031A: "Property: Sensor State",
    0x031B: "Property: Sensor Event",
}

# HID Global Unit item values, named as the kernel's unit_conversion[] table in
# drivers/iio/common/hid-sensors/hid-sensor-attributes.c matches them.  The
# ITE8350 uses these short codes; they are NOT valid SI nibble encodings, so
# decode_unit() falls back to the name rather than a nibble breakdown.
KNOWN_UNITS = {
    0x00: "NOT_SPECIFIED",
    0x01: "LUX",
    0x12: "RADIANS",
    0x14: "DEGREES",
    0x15: "DEGREES_PER_SECOND",
    0x1A: "G",
    0x1C: "GAUSS",
    0x010000: "KELVIN",
    0x030000: "FAHRENHEIT",
    0xF1E1: "PASCAL",
}


def sgn(val, nbytes):
    """Interpret an nbytes-wide little-endian item payload as signed."""
    if nbytes and val >= (1 << (nbytes * 8 - 1)):
        val -= 1 << (nbytes * 8)
    return val


def unit_exponent(nibble):
    """HID Unit Exponent is a 4-bit signed value: 0..7 = 0..7, 8..15 = -8..-1."""
    return nibble - 16 if nibble > 7 else nibble


def decode_unit(unit):
    """Render a HID Global Unit item as its SI nibble breakdown."""
    if unit == 0:
        return "None"
    systems = {1: "SI Linear", 2: "SI Rotation",
               3: "English Linear", 4: "English Rotation"}
    nib = [(unit >> (4 * i)) & 0xF for i in range(8)]
    if nib[0] not in systems:
        # Not an SI nibble encoding -- a short HID-sensor unit code.
        return KNOWN_UNITS.get(unit, f"unknown code 0x{unit:x}")
    parts = [systems[nib[0]]]
    for name, i in (("Length", 1), ("Mass", 2), ("Time", 3), ("Temp", 4),
                    ("Current", 5), ("Luminous", 6)):
        e = unit_exponent(nib[i])
        if e:
            parts.append(f"{name}^{e}")
    return " ".join(parts)


def items(buf):
    """Walk the descriptor, yielding (type, tag, value, size, offset)."""
    i = 0
    while i < len(buf):
        prefix = buf[i]
        if prefix == 0xFE:          # long item -- not used by sensor hubs
            size = buf[i + 1]
            yield ("long", 0, 0, size, i)
            i += 3 + size
            continue
        size = prefix & 0x03
        size = 4 if size == 3 else size
        itype = (prefix >> 2) & 0x03
        tag = (prefix >> 4) & 0x0F
        val = int.from_bytes(buf[i + 1:i + 1 + size], "little")
        yield (("Main", "Global", "Local", "Reserved")[itype], tag, val, size, i)
        i += 1 + size


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    fields_only = "--fields" in sys.argv
    with open(path, "rb") as f:
        buf = f.read()

    # Global state carried across items, per the HID spec.
    g = {"page": 0, "unit": 0, "expo": 0, "lmin": 0, "lmax": 0,
         "rsize": 0, "rcount": 0, "rid": None}
    stack = []
    usages = []          # local usages, cleared by every Main item
    sensor = None        # innermost sensor type collection we are inside
    depth = 0

    if not fields_only:
        print(f"# {path} -- {len(buf)} bytes\n")

    for itype, tag, val, size, off in items(buf):
        if itype == "Global":
            name = GLOBAL_TAGS.get(tag, f"Global({tag})")
            if tag == 0:
                g["page"] = val
            elif tag == 1:
                g["lmin"] = sgn(val, size)
            elif tag == 2:
                g["lmax"] = sgn(val, size)
            elif tag == 5:
                g["expo"] = unit_exponent(val & 0xF)
            elif tag == 6:
                g["unit"] = val
            elif tag == 7:
                g["rsize"] = val
            elif tag == 8:
                g["rid"] = val
            elif tag == 9:
                g["rcount"] = val
            if not fields_only:
                extra = ""
                if tag == 6:
                    extra = f"  [{decode_unit(val)}]"
                    if val in KNOWN_UNITS:
                        extra += f" = HID_USAGE_SENSOR_UNITS_{KNOWN_UNITS[val]}"
                print(f"{off:04x} {'  ' * depth}{name} = 0x{val:x}{extra}")

        elif itype == "Local":
            name = LOCAL_TAGS.get(tag, f"Local({tag})")
            if tag == 0:
                usages.append(val)
            if not fields_only:
                lbl = ""
                if g["page"] == 0x20:
                    lbl = DATA_FIELDS.get(val, SENSOR_TYPES.get(val, ""))
                elif g["page"] >= 0xFF00:
                    lbl = "vendor-defined"
                print(f"{off:04x} {'  ' * depth}{name} = 0x{val:04x}"
                      + (f"  ({lbl})" if lbl else ""))

        elif itype == "Main":
            name = MAIN_TAGS.get(tag, f"Main({tag})")
            if tag == 10:                      # Collection
                if g["page"] == 0x20 and usages and usages[0] in SENSOR_TYPES:
                    stack.append(sensor)
                    sensor = SENSOR_TYPES[usages[0]]
                else:
                    stack.append(sensor)
                if not fields_only:
                    print(f"{off:04x} {'  ' * depth}Collection "
                          f"({COLLECTIONS.get(val, val)})"
                          + (f"  <-- {sensor}" if sensor else ""))
                depth += 1
            elif tag == 12:                    # End Collection
                depth = max(0, depth - 1)
                sensor = stack.pop() if stack else None
                if not fields_only:
                    print(f"{off:04x} {'  ' * depth}End Collection")
            else:
                if fields_only and tag in (8, 11) and usages:
                    for u in usages:
                        if g["page"] != 0x20 or u not in DATA_FIELDS:
                            continue
                        unit_name = KNOWN_UNITS.get(g["unit"], "")
                        print(f"{sensor or '-':<34} "
                              f"{DATA_FIELDS[u]:<32} "
                              f"{name:<8} "
                              f"rid={g['rid']:<4} "
                              f"size={g['rsize']:<3} "
                              f"logical=[{g['lmin']},{g['lmax']}] "
                              f"unit=0x{g['unit']:08x}"
                              f"{'(' + unit_name + ')' if unit_name else ''} "
                              f"expo={g['expo']}")
                elif not fields_only:
                    print(f"{off:04x} {'  ' * depth}{name} (0x{val:02x}) "
                          f"rid={g['rid']} size={g['rsize']} count={g['rcount']} "
                          f"unit=0x{g['unit']:x} expo={g['expo']}")
            usages = []

    return 0


if __name__ == "__main__":
    sys.exit(main())
