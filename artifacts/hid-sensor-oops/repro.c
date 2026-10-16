/*
 * Reproduce the hid-sensor-attributes divide-by-zero in userspace.
 *
 * See docs/68-hid-sensor-hysteresis-oops.md. Writing any value to an
 * `in_*_hysteresis` attribute whose HID unit exponent is -7 or -8 takes a
 * kernel divide error in convert_to_vtf_format(). This program shows why
 * without a kernel, a HID sensor hub, or root: int_pow() is lib/math/int_pow.c
 * verbatim and hid_sensor_convert_exponent() is include/linux/hid-sensor-hub.h
 * verbatim, both as of mainline 2f2f7eeef8b0 (2026-10-15).
 *
 * It deliberately computes the divisor and reports whether it is zero rather
 * than performing the division, so running it is safe.
 *
 *     cc -O2 -o repro repro.c && ./repro
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

static uint64_t int_pow(uint64_t base, unsigned int exp)
{
	uint64_t result = 1;
	while (exp) {
		if (exp & 1) result *= base;
		exp >>= 1;
		base *= base;
	}
	return result;
}

static int hid_sensor_convert_exponent(int unit_expo)
{
	if (unit_expo < 0x08) return unit_expo;
	else if (unit_expo <= 0x0f) return -(0x0f - unit_expo + 1);
	else return 0;
}

int main(void)
{
	printf("nibble  exp   6+exp  int_pow(10, 6+exp) as `int divisor`   write\n");
	for (int nib = 0x0; nib <= 0xf; nib++) {
		int exp = hid_sensor_convert_exponent(nib);
		if (exp >= 0) continue;                 /* the other branch */
		int divisor = (int)int_pow(10, 6 + exp);  /* kernel: int divisor */
		printf("  0x%x   %3d   %5d   %-34d  %s\n", nib, exp, 6 + exp, divisor,
		       divisor == 0 ? "*** divide error ***" : "ok");
	}
	return 0;
}
