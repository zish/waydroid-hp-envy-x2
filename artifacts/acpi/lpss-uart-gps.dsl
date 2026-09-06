// Excerpts from bigtab01's DSDT relevant to the GPS receiver and the LPSS UART
// it hangs off.  Regenerate the full listing with:
//     iasl -d DSDT.aml     (acpica-tools; DSDT.aml is in this directory)
// Line numbers below are from that listing, iasl 20250404.

// ------------------------------------------------------------------
// DSDT:12391  OSYS is set from _OSI.  Linux answers _OSI("Windows 2013"),
// so OSYS == 0x07DD on this host.  Proven below, not assumed.
// ------------------------------------------------------------------
        Method (_INI, 0, Serialized)  // _INI: Initialize
        {
            OSYS = 0x07D9
            If (CondRefOf (\_OSI, Local0))
            {
                If (_OSI ("Windows 2009"))
                {
                    If (((_REV == 0x03) || (_REV == 0x05)))
                    {
                        OSYS = 0x03E9
                    }
                    Else
                    {
                        OSYS = 0x07D9
                    }
                }

                If (_OSI ("Windows 2012"))
                {
                    OSYS = 0x07DC
                }

                If (_OSI ("Windows 2013"))
                {
                    OSYS = 0x07DD
                }

                If (_OSI ("!Windows 2009"))
                {
                    OSYS = 0x03E8
                }

                If (_OSI ("NOT_WINP_KEY"))
                {
                    OSYS = 0x03E8
                }

                If (_OSI ("WINP_NOT"))
                {
                    OSYS = 0x03E9
                }
            }


// ------------------------------------------------------------------
// DSDT:5628  I2C0 / INT3432 _STA -- THE CONTROL CASE.
// Reports status=15 on the host, and carries the identical OSYS gate,
// which is what proves OSYS >= 0x07DD and pins the blame on SMDn.
// ------------------------------------------------------------------
            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                If ((SMD1 == Zero))
                {
                    Return (Zero)
                }

                If ((OSYS < 0x07DD))
                {
                    Return (Zero)
                }

                Return (0x0F)
            }
        }

// ------------------------------------------------------------------
// DSDT:5972  UART0 / INT3434 (\_SB.PCI0.UA00) -- the GPS's UART.
// Reports status=0.  OSYS is ruled out above, so SMD5 == 0:
// the firmware has SerialIO UART0 set to Disabled in ACPI NVS.
// ------------------------------------------------------------------
    If ((SMD5 != 0x02))
    {
        Scope (_SB.PCI0.UA00)
        {
            Method (_HID, 0, NotSerialized)  // _HID: Hardware ID
            {
                If ((SMD5 == 0x03))
                {
                    Return (0x020CD041)
                }

                If ((PCHG == 0x02))
                {
                    Return ("INT3434")
                }

                Return ("INT33C4")
            }

            Method (_HRV, 0, NotSerialized)  // _HRV: Hardware Revision
            {
                Return (^^LPCB.CRID) /* \_SB_.PCI0.LPCB.CRID */
            }

            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                If ((SMD5 == Zero))
                {
                    Return (Zero)
                }

                If ((OSYS < 0x07DD))
                {
                    Return (Zero)
                }

                Return (0x0F)
            }
        }
    }

// ------------------------------------------------------------------
// DSDT:6300  GPS0.  Note _STA is a hardcoded Return (0x0F) -- it checks
// nothing, so "present and functioning" is an unconditional claim by a
// DSDT shared across the whole Envy x2 13 family.  It is NOT evidence
// that a receiver is fitted on this unit.
// ------------------------------------------------------------------
    Scope (_SB.PCI0.UA00)
    {
        Device (GPS0)
        {
            Name (_HID, "HPQC4752")  // _HID: Hardware ID
            Name (_HRV, Zero)  // _HRV: Hardware Revision
            Method (_CRS, 0, NotSerialized)  // _CRS: Current Resource Settings
            {
                Name (UBUF, ResourceTemplate ()
                {
                    UartSerialBusV2 (0x0001C200, DataBitsEight, StopBitsOne,
                        0xFC, LittleEndian, ParityTypeNone, FlowControlHardware,
                        0x0020, 0x0020, "\\_SB.PCI0.UA00",
                        0x00, ResourceConsumer, , Exclusive,
                        )
                    GpioIo (Exclusive, PullDefault, 0x0000, 0x0000, IoRestrictionOutputOnly,
                        "\\_SB.PCI0.GPI0", 0x00, ResourceConsumer, ,
                        )
                        {   // Pin list
                            0x0011
                        }
                })
                Return (UBUF) /* \_SB_.PCI0.UA00.GPS0._CRS.UBUF */
            }

            Method (_STA, 0, NotSerialized)  // _STA: Status
            {
                Return (0x0F)
            }
        }
    }


// ------------------------------------------------------------------
// DSDT:5264  LCRS -- builds each LPSS device's _CRS from NVS: one
// Memory32Fixed of 0x1000 at SBnn, plus one Interrupt at SIRn.
// ------------------------------------------------------------------
        Method (LCRS, 3, Serialized)
        {
            Name (RBUF, ResourceTemplate ()
            {
                Memory32Fixed (ReadWrite,
                    0x00000000,         // Address Base
                    0x00001000,         // Address Length
                    _Y11)
                Interrupt (ResourceConsumer, Level, ActiveLow, Shared, ,, _Y12)
                {
                    0x00000014,
                }
            })
            CreateDWordField (RBUF, \_SB.PCI0.LCRS._Y11._BAS, BVAL)  // _BAS: Base Address
            CreateDWordField (RBUF, \_SB.PCI0.LCRS._Y11._LEN, BLEN)  // _LEN: Length
            CreateDWordField (RBUF, \_SB.PCI0.LCRS._Y12._INT, IRQN)  // _INT: Interrupts
            BVAL = Arg1
            IRQN = Arg2
            If ((Arg0 == 0x03))
            {
                BLEN = 0x08
            }

            Return (RBUF) /* \_SB_.PCI0.LCRS.RBUF */
        }


// ------------------------------------------------------------------
// DSDT:2793  Where SMD5 lives: the platform NVS OperationRegion.
// ------------------------------------------------------------------
    Name (PNVB, 0x9CFBDD98)
    Name (PNVL, 0x00E4)
    OperationRegion (PNVA, SystemMemory, PNVB, PNVL)
    Field (PNVA, AnyAcc, Lock, Preserve)
    {
