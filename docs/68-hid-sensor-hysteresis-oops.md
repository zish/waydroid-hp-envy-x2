# A legal HID unit exponent divides by zero in the kernel

Found on bigtab01 on 2026-10-15 while probing whether the ITE8350 sensor hub could push samples
instead of being polled ([docs/67](67-sensor-poll-cost.md)). Five kernel oopses were taken working
it out. **Not reported upstream yet** — see [Submitting it](#submitting-it-when-we-get-to-it).

It is upstream code, unmodified: mainline HEAD `2f2f7eeef8b0` (2026-10-15) still has it, and the
last substantive change to the file is from 2021. Nothing in this project writes the attribute
involved — the only mention of hysteresis anywhere in `waydroid-sensord` is a comment. The writes
came from `bin/iio-push-probe.py`, as root, deliberately defeating the hub's change-sensitivity
threshold to see whether push mode could work.

## What happens

Writing **any** value to `in_*_hysteresis` on an affected channel kills the writing task:

```
Oops: divide error: 0000 [#1] SMP PTI
CPU: 0 UID: 0 PID: 19455 Comm: python3 Tainted: G I  7.2.8-200.fc44.x86_64
Hardware name: Hewlett-Packard HP ENVY x2 Detachable PC 13/22E0
RIP: 0010:convert_to_vtf_format+0x78/0xa0 [hid_sensor_iio_common]
Code: ... bf 0a 00 00 00 ... f7 de ... 0f af d8 8b 44 24 04 99 <41> f7 fe ...
RAX: 0000000000000000 RBX: 0000000000000000 RCX: 0000000000000000
RDX: 0000000000000000 RSI: 0000000000000000 RDI: 0000000000002710
R13: ffffcfbf8f18fd10 R14: 0000000000000000 R15: 0000000000000000
Call Trace:
  hid_sensor_write_raw_hyst_value+0x4b/0xe0 [hid_sensor_iio_common]
  iio_write_channel_info+0x148/0x200 [industrialio]
  kernfs_fop_write_iter / vfs_write / ksys_write / do_syscall_64
```

The faulting instruction is `41 f7 fe`, `idiv r14d`, and `R14 = 0`.

## The mechanism

`drivers/iio/common/hid-sensors/hid-sensor-attributes.c`:

```c
static u32 convert_to_vtf_format(int size, int exp, int val1, int val2)
{
	int divisor;
	...
	exp = hid_sensor_convert_exponent(exp);
	if (exp < 0) {
		divisor = int_pow(10, 6 + exp);
		value = abs(val1) * int_pow(10, -exp);
		value += abs(val2) / divisor;          /* <- the idiv */
	}
```

`include/linux/hid-sensor-hub.h`:

```c
static inline int hid_sensor_convert_exponent(int unit_expo)
{
	if (unit_expo < 0x08)       return unit_expo;                /* 0x0-0x7 ->  0..7 */
	else if (unit_expo <= 0x0f) return -(0x0f - unit_expo + 1);  /* 0x8-0xF -> -8..-1 */
	else                        return 0;
}
```

So `exp` legitimately ranges over −8..7, which is precisely the HID spec's nibble encoding for a
unit exponent. When `exp` is −7 or −8, `6 + exp` is **negative**. `int_pow()` takes its exponent as
`unsigned int`:

```c
u64 int_pow(u64 base, unsigned int exp)
{
	u64 result = 1;
	while (exp) {
		if (exp & 1) result *= base;
		exp >>= 1;
		base *= base;
	}
	return result;
}
```

`−1` becomes 4294967295, and exponentiation by squaring then walks `base` through 10¹, 10², 10⁴ …
10⁶⁴. Since 10 = 2·5, any 10ⁿ with n ≥ 64 is ≡ 0 mod 2⁶⁴, so `base` becomes exactly 0 on the
seventh squaring and every later set bit multiplies `result` by it. `int_pow` returns **0**, that
becomes the divisor, and the next instruction faults.

**No malformed descriptor is needed.** Two of the sixteen legal values crash:

| nibble | `exp` | `6 + exp` | divisor | write |
|---|---|---|---|---|
| 0x8 | −8 | −2 | **0** | **divide error** |
| 0x9 | −7 | −1 | **0** | **divide error** |
| 0xa | −6 | 0 | 1 | ok |
| 0xb | −5 | 1 | 10 | ok |
| 0xc | −4 | 2 | 100 | ok |
| 0xd | −3 | 3 | 1000 | ok |
| 0xe | −2 | 4 | 10000 | ok |
| 0xf | −1 | 5 | 100000 | ok |

### Correction to the first account of this

[docs/67](67-sensor-poll-cost.md) first said the divisor came from `pow_10()` overflowing because
it "multiplies a 32-bit `int` by ten in a loop". Both halves are wrong. The function is
`int_pow()`, it accumulates in `u64`, and the zero does not come from multiplying past 32 bits at
all — it comes from the **exponent** being converted to unsigned, which is a different bug with the
same symptom. `pow_10()` was the old spelling of this helper and is not in any current tree. The
conclusion survived the correction; the explanation did not, and the explanation is the part that
tells you where the fix goes.

## Why it was so precisely selective

This was the detail that turned "the hub is flaky" into "this is a real mechanism". Writes to four
of the five nodes' hysteresis attributes completed normally; only `dev_rotation`'s killed the task:

| node | LSB | implied exponent | hysteresis write |
|---|---|---|---|
| `dev_rotation` | 1e-7 (quaternion) | **−7** | **oops** |
| `magn_3d` | 1e-4 µT | −4 | ok |
| `accel_3d` | ~1e-3 g | −3 | ok |
| `incli_3d` | 1e-1 deg | −1 | ok |
| `gyro_3d` | 1.75e-7 rad/s, reported in deg/s at 1e-5 | −5 | ok |

A dimensionless unit quaternion at 1e-7 per LSB is exactly the kind of channel that needs an
exponent past −6, and it is the only one on this machine that has one.

The exponents in that table are **inferred** from each channel's LSB, and strictly the value this
code path uses is `st->sensitivity.unit_expo` — the exponent of the *sensitivity* field, which a
descriptor need not declare with the same exponent as the data field. So the table is a prediction
that the observed pattern corroborates, not a reading of the descriptor. Confirming it properly
means dumping the HID report descriptor ([`bin/hid-decode.py`](../bin/hid-decode.py)) and finding
the sensitivity field for usage `HID_USAGE_SENSOR_DATA_ORIENTATION`, which has not been done.

## Reproducing it without the hardware

[`artifacts/hid-sensor-oops/repro.c`](../artifacts/hid-sensor-oops/repro.c) is `int_pow()` and
`hid_sensor_convert_exponent()` copied verbatim from mainline, and prints the table above. It
computes the divisor and reports whether it is zero rather than dividing, so it is safe to run:

```sh
cc -O2 -o repro artifacts/hid-sensor-oops/repro.c && ./repro
```

That is the whole proof, and it needs no kernel, no HID hub and no root — which matters, because
the alternative way to confirm it is to oops the machine a sixth time.

On real hardware the trigger is simply:

```sh
# don't, unless you mean it
cat /sys/bus/iio/devices/iio:deviceN/in_rot_hysteresis > /tmp/v
cat /tmp/v > /sys/bus/iio/devices/iio:deviceN/in_rot_hysteresis    # task dies here
```

Note that writing back the value it already had is enough. There is no read-modify-write to get
wrong and no need for an unusual value.

## How bad it is

Modest, and worth saying so plainly rather than dressing it up:

- The attributes are `-rw-r--r-- root root`, so this is **root-only**. No privilege escalation,
  nothing remotely reachable.
- It kills the writing task. The machine carries on: bigtab01 has `panic_on_oops = 0` and took
  five of these without any other ill effect — all five IIO nodes kept reading, the sensors HAL
  never noticed, and `bin/sensors-test.sh` passed immediately afterwards.
- On a host with `panic_on_oops = 1` the same root write is a **full panic** instead.
- The hub logs `i2c_hid_acpi ... failed to set a report to device: -121` afterwards, because the
  task died mid-HID-transfer — 13 of them across the five oopses. That is a second cause for a
  symptom [docs/19](19-sensor-hub-suspend-wedge.md) had previously only seen after suspend.

The reason it has apparently gone unnoticed is that almost nothing writes `in_*_hysteresis`.
`iio-sensor-proxy` does not, desktop stacks do not, and you would only reach for it if you were
trying to make a HID hub push unsolicited reports. Combine that with needing a channel at exponent
−7 or −8 and the overlap is narrow.

## The fix

`val2` is in micro-units, so expressing it in units of 10^`exp` means scaling by 10^(−6−`exp`) —
a division by 10^(6+`exp`) when that exponent is non-negative, and a **multiplication** when it is
not. The current code only implements the division case:

```diff
 	if (exp < 0) {
-		divisor = int_pow(10, 6 + exp);
 		value = abs(val1) * int_pow(10, -exp);
-		value += abs(val2) / divisor;
+		if (exp >= -6)
+			value += abs(val2) / int_pow(10, 6 + exp);
+		else
+			value += abs(val2) * int_pow(10, -exp - 6);
 	}
```

The read path has the same mistake mirrored, and it is worth fixing in the same patch even though
it does not crash. `split_micro_fraction()` computes

```c
	*val2 = no % divisor * int_pow(10, 6 - exp);
```

where the caller passes `-exp`, so `exp` here is 1..8. For `exp > 6` the inner `6 - exp` underflows
the same way, `int_pow` returns 0, and the fractional part is **silently zeroed** — a wrong reading
rather than an oops, which is arguably worse to debug.

`hid_sensor_write_samp_freq_value()` reaches `convert_to_vtf_format()` through the *poll* interval's
unit exponent rather than the sensitivity's, so `in_*_sampling_frequency` writes are suspect by the
same argument. Deliberately untested: this is the owner's daily-driver machine and five oopses were
enough. Fixing the conversion fixes both callers regardless.

## Submitting it, when we get to it

**Not through GitHub.** Verified rather than assumed:

```
repos/torvalds/linux -> has_issues: false
repos/torvalds/linux/pulls -> 404 Not Found
```

Issues and pull requests are both disabled on the mirror, so `gh issue create` and `gh pr create`
have no target. The kernel takes patches by email.

From `MAINTAINERS`, `drivers/iio/*/hid-*` and `include/linux/hid-sensor-*` fall under **HID SENSOR
HUB DRIVERS**:

| | |
|---|---|
| maintainers | Jiri Kosina `<jikos@kernel.org>`, Jonathan Cameron `<jic23@kernel.org>`, Srinivas Pandruvada `<srinivas.pandruvada@linux.intel.com>` |
| lists | `linux-input@vger.kernel.org`, `linux-iio@vger.kernel.org`, + LKML by convention |
| mechanism | `git send-email` a `[PATCH]` thread |
| tree | `git://git.kernel.org/pub/scm/linux/kernel/git/jic23/iio.git` |

No SMTP or sendmail identity is configured on the dev box, so sending needs setting up first. And
the `Signed-off-by:` is a provenance assertion only the author can make, so the patch wants reading
before it goes out under anyone's name.

## What is verified and what is not

| | |
|---|---|
| the oops is real and reproducible | **yes** — five of them, one trace quoted above in full |
| the mechanism | **yes** — `repro.c` derives the divisor of 0 from upstream source, no hardware |
| the bug is in current mainline | **yes** — read at HEAD `2f2f7eeef8b0`, 2026-10-15 |
| only exponents −7 and −8 are affected | **yes**, for this call path, per the table |
| the per-channel selectivity matches the mechanism | **yes** — four nodes' writes completed, the one at −7 did not |
| the proposed fix compiles or is correct | **no** — not built against a kernel tree, not tested |
| `in_*_sampling_frequency` is affected too | **no** — argued from shared code, never exercised |
| nobody has already reported it | **NO** — the `lore.kernel.org` duplicate search was attempted and returned nothing parseable. Do this first |
