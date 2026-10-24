/*
 * The whole test framework for the Kotlin apps' unit tests: named cases,
 * failures collected rather than fatal, a summary line, and an exit status.
 *
 * No JUnit, for the reason the apps have no Gradle -- nothing to fetch and
 * nothing to configure. Assertions are kotlin.test's, which ships inside the
 * kotlinc distribution the apps already build with and throws a plain
 * AssertionError when no JUnit is on the classpath.
 *
 * An app's tests live in <app>/test/, compiled together with the app's whole
 * src/ against android.jar. Its entry point is <app>/test/Tests.kt:
 *
 *     package com.systemhalted.bluetooth
 *     import testharness.suite
 *     fun main() = suite("bt-app") {
 *         test("absent range means API 1") { assertEquals(...) }
 *     }
 *
 * android.jar is the stub jar: every Android method throws "Stub!" when
 * called. So these tests can reach code that merely MENTIONS Android types,
 * and must not call into the framework -- logic that needs to be tested is
 * logic that should not need a Context. org.json is the exception: a real
 * implementation is put ahead of the stubs on the classpath (tests/run.sh).
 */
package testharness

import kotlin.system.exitProcess

class Suite(private val name: String) {
    private var passed = 0
    private val failed = mutableListOf<String>()

    fun test(case: String, body: () -> Unit) {
        try {
            body()
            passed++
        } catch (t: Throwable) {
            failed += case
            System.err.println("FAIL $name: $case")
            System.err.println("     $t")
            // The first frame inside the app or the test, which is where the
            // assertion that failed actually is.
            t.stackTrace.firstOrNull { it.className.startsWith("com.systemhalted.") }
                ?.let { System.err.println("     at ${it.fileName}:${it.lineNumber}") }
        }
    }

    internal fun finish(): Nothing {
        val total = passed + failed.size
        println("$name: $total tests, ${failed.size} failed")
        exitProcess(if (failed.isEmpty()) 0 else 1)
    }
}

fun suite(name: String, block: Suite.() -> Unit) {
    val s = Suite(name)
    s.block()
    s.finish()
}
