# Waydroid health HAL — battery fix

Both files are `/vendor/bin/hw/android.hardware.health@2.0-service.waydroid`, pulled from the
running vendor image on bigtab01 (LineageOS 20, `20.0-20260403-GAPPS-waydroid_x86_64`).

| File | md5 | |
|---|---|---|
| `…waydroid.orig` | `683f57b83e627b7ef3f95b49dc0cbde9` | as shipped |
| `…waydroid` | `4afd21084e721f3bee2dba77c2fbd274` | deployed |

The only difference is three bytes at **file offset `0x6730`** (VMA `0x7730`, the start of
`healthd_board_battery_update`), which turn it into a no-op so the real values `BatteryMonitor`
read from the host's `/sys/class/power_supply` reach Android untouched:

```
before: 50 66 c7      push rax / mov WORD PTR [rdi],0x101 …
after:  31 c0 c3      xor eax,eax ; ret
```

Reproduce from the original without this repo:

```bash
printf '\x31\xc0\xc3' | dd of=<binary> bs=1 seek=$((0x6730)) conv=notrunc
```

Deploy to `/var/lib/waydroid/overlay/vendor/bin/hw/` as **mode 0755**, then
`waydroid session stop && waydroid session start` — a `container restart` will not pick it up.

Full reasoning in [docs/10-battery-fixed.md](../../docs/10-battery-fixed.md).
