/*
 * A test-side stand-in for the R class media-app/build.sh generates.
 *
 * media-app is the one app here whose sources use their own R: the
 * notification needs a real drawable id (build.sh explains why
 * getIdentifier() was rejected), so build.sh runs aapt2 with --java and
 * compiles the R.java it writes. tests/run.sh compiles src/ with kotlinc alone
 * and runs no aapt2, so without this file Volumes.kt and StatusActivity.kt
 * would not compile for the tests at all.
 *
 * It declares exactly the ids src/ references -- found by grepping src/ for
 * "R." and checked against res/ -- and nothing more. A new R reference in
 * src/ therefore fails the TEST compile with an unresolved reference, which is
 * intended: add the id here when that happens, rather than letting this file
 * grow a speculative copy of res/.
 *
 * The values are never meaningful. aapt2 assigns real ones (0x7f...); here
 * they only need to exist and be distinct, and no test may assert on them.
 * Nothing in the tests resolves a resource -- that would call into the
 * android.jar stubs and throw "Stub!".
 */
package com.systemhalted.removablemedia

object R {
    object string {
        const val app_name = 0x7f010001
        const val channel_name = 0x7f010002
        const val channel_desc = 0x7f010003
        const val eject = 0x7f010004
        const val ejecting = 0x7f010005
    }

    object drawable {
        const val ic_media = 0x7f020001
    }
}
