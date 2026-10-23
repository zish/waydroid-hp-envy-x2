/*
 * Copyright 2026 Jeremy Melanson
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
package com.systemhalted.keystoreprobe

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.Log
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.Signature
import java.security.cert.X509Certificate
import java.security.spec.X509EncodedKeySpec
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.SecretKeyFactory
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.IvParameterSpec

/**
 * Asks AndroidKeyStore for StrongBox keys exactly as an app would, uses them, and
 * checks every result against something that is not the keystore.
 *
 * - A signature is verified with the platform's ordinary software provider, from a
 *   copy of the public key that has never been near AndroidKeyStore.
 * - A key's certificate is checked against its own public key. keystore2 asks the
 *   StrongBox to sign that certificate with the new key, through begin/finish, and
 *   silently signs it with a throwaway key instead if that fails -- so this check
 *   is the only visible sign of whether the signing pass during key generation
 *   worked.
 * - `KeyInfo.getSecurityLevel()` says where the key actually is. Without it a
 *   StrongBox request that quietly fell back would look like success.
 * - A TEE key of the same shape runs first, as the control: if it fails too, the
 *   fault is not ours.
 *
 * Every step is guarded, so one failure is reported and the rest still run.
 */
class Probe {
    companion object {
        const val TAG = "KeystoreProbe"
        private const val SB_EC = "probe-sb-ec"
        private const val SB_GCM = "probe-sb-gcm"
        private const val SB_CBC = "probe-sb-cbc"
        private const val TEE_EC = "probe-tee-ec"
    }

    private val out = StringBuilder()
    private var pass = 0
    private var fail = 0
    private val ks: KeyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    private fun line(s: String) {
        out.append(s).append('\n')
        Log.i(TAG, s)
    }

    private fun check(ok: Boolean, what: String, detail: String = "") {
        if (ok) pass++ else fail++
        line("  [${if (ok) "PASS" else "FAIL"}] $what" + if (detail.isEmpty()) "" else "  ($detail)")
    }

    /** An exception chain, with keystore's numeric error code where there is one. */
    private fun describe(t: Throwable): String {
        val parts = ArrayList<String>()
        var c: Throwable? = t
        while (c != null && parts.size < 5) {
            var s = "${c.javaClass.simpleName}: ${c.message}"
            try {
                val m = c.javaClass.getMethod("getNumericErrorCode")
                s += " [code ${m.invoke(c)}]"
            } catch (_: Throwable) {
            }
            parts.add(s)
            c = c.cause
        }
        return parts.joinToString(" <- ")
    }

    private inline fun step(what: String, body: () -> Unit) {
        try {
            body()
        } catch (t: Throwable) {
            fail++
            line("  [FAIL] $what: ${describe(t)}")
            Log.w(TAG, what, t)
        }
    }

    private fun <T> timed(label: String, body: () -> T): T {
        val t0 = System.nanoTime()
        val r = body()
        line("  [time] $label: ${(System.nanoTime() - t0) / 1_000_000} ms")
        return r
    }

    private fun levelName(l: Int) = when (l) {
        KeyProperties.SECURITY_LEVEL_STRONGBOX -> "STRONGBOX"
        KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT -> "TRUSTED_ENVIRONMENT"
        KeyProperties.SECURITY_LEVEL_SOFTWARE -> "SOFTWARE"
        KeyProperties.SECURITY_LEVEL_UNKNOWN_SECURE -> "UNKNOWN_SECURE"
        else -> "UNKNOWN($l)"
    }

    private fun levelOf(key: PrivateKey): Int =
        KeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
            .getKeySpec(key, KeyInfo::class.java).securityLevel

    private fun levelOf(key: SecretKey): Int =
        (SecretKeyFactory.getInstance(key.algorithm, "AndroidKeyStore")
            .getKeySpec(key, KeyInfo::class.java) as KeyInfo).securityLevel

    private fun message(n: Int) = ByteArray(n) { (it * 31 + 7).toByte() }

    fun run(): String {
        line("Keystore Probe")
        line("  ${Build.FINGERPRINT}")
        line("  SDK ${Build.VERSION.SDK_INT}")

        for (a in listOf(SB_EC, SB_GCM, SB_CBC, TEE_EC)) {
            try { ks.deleteEntry(a) } catch (_: Throwable) {}
        }

        line("")
        line("-- control: an EC key in the TEE --")
        ecKey(TEE_EC, strongBox = false)

        line("")
        line("-- StrongBox EC P-256 --")
        ecKey(SB_EC, strongBox = true)

        line("")
        line("-- StrongBox AES-256-GCM --")
        gcmKey()

        line("")
        line("-- StrongBox AES-128-CBC/PKCS7 --")
        cbcKey()

        line("")
        line("-- cleanup --")
        step("delete the probe's keys") {
            for (a in listOf(SB_EC, SB_GCM, SB_CBC, TEE_EC)) ks.deleteEntry(a)
            check(listOf(SB_EC, SB_GCM, SB_CBC, TEE_EC).none { ks.containsAlias(it) },
                "keys deleted")
        }

        line("")
        line("$pass passed, $fail failed")
        return out.toString()
    }

    private fun ecKey(alias: String, strongBox: Boolean) {
        step("generate") {
            val spec = KeyGenParameterSpec.Builder(alias,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setDigests(KeyProperties.DIGEST_SHA256)
                .setIsStrongBoxBacked(strongBox)
                .build()
            val kpg = KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC,
                "AndroidKeyStore")
            kpg.initialize(spec)
            val kp = timed("generateKeyPair") { kpg.generateKeyPair() }
            check(true, "generateKeyPair")

            val level = levelOf(kp.private)
            if (strongBox) {
                check(level == KeyProperties.SECURITY_LEVEL_STRONGBOX,
                    "KeyInfo security level is STRONGBOX", "got ${levelName(level)}")
            } else {
                // Not asserted: this image's default keymaster is a software one
                // that keystore2 wraps as the TEE level, and KeyInfo says SOFTWARE
                // (measured 2026-10-22). The control is about the flow working.
                line("  [info] control key security level: ${levelName(level)}")
            }

            val cert = ks.getCertificate(alias) as X509Certificate
            val selfSigned = try { cert.verify(cert.publicKey); true } catch (_: Throwable) { false }
            check(selfSigned, "certificate is signed by the key itself",
                if (selfSigned) "the signing pass during generation worked"
                else "keystore2 fell back to a throwaway signing key")

            val msg = message(1000)
            val sig = timed("sign 1000 bytes") {
                Signature.getInstance("SHA256withECDSA").run {
                    initSign(kp.private)
                    update(msg)
                    sign()
                }
            }
            // A public key with no AndroidKeyStore in its history, verified by the
            // ordinary software provider.
            val plainPub = KeyFactory.getInstance("EC")
                .generatePublic(X509EncodedKeySpec(kp.public.encoded))
            val ok = Signature.getInstance("SHA256withECDSA").run {
                initVerify(plainPub)
                update(msg)
                verify(sig)
            }
            check(ok, "signature verifies in software", "${sig.size}-byte DER")
            val tampered = msg.copyOf().also { it[0] = (it[0] + 1).toByte() }
            val bad = Signature.getInstance("SHA256withECDSA").run {
                initVerify(plainPub)
                update(tampered)
                verify(sig)
            }
            check(!bad, "and does not verify over a different message")
        }
    }

    private fun gcmKey() {
        step("AES-GCM") {
            val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            kg.init(KeyGenParameterSpec.Builder(SB_GCM,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setIsStrongBoxBacked(true)
                .build())
            val key = timed("generateKey") { kg.generateKey() }
            check(true, "generateKey")
            val level = levelOf(key)
            check(level == KeyProperties.SECURITY_LEVEL_STRONGBOX,
                "KeyInfo security level is STRONGBOX", "got ${levelName(level)}")

            val aad = "header".toByteArray()
            for (size in listOf(37, 100_000)) {
                val pt = message(size)
                val enc = Cipher.getInstance("AES/GCM/NoPadding")
                enc.init(Cipher.ENCRYPT_MODE, key)
                enc.updateAAD(aad)
                val ct = timed("encrypt $size bytes") { enc.doFinal(pt) }
                val iv = enc.iv
                check(iv != null && iv.size == 12 && ct.size == size + 16,
                    "encrypt $size bytes: keystore-chosen 12-byte IV, 16-byte tag",
                    "iv ${iv?.size}, ct ${ct.size}")

                val dec = Cipher.getInstance("AES/GCM/NoPadding")
                dec.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, iv))
                dec.updateAAD(aad)
                val back = timed("decrypt $size bytes") { dec.doFinal(ct) }
                check(back.contentEquals(pt), "decrypt $size bytes round-trips")
            }

            val pt = message(64)
            val enc = Cipher.getInstance("AES/GCM/NoPadding")
            enc.init(Cipher.ENCRYPT_MODE, key)
            val ct = enc.doFinal(pt)
            ct[ct.size - 1] = (ct[ct.size - 1] + 1).toByte()
            val dec = Cipher.getInstance("AES/GCM/NoPadding")
            dec.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(128, enc.iv))
            val rejected = try { dec.doFinal(ct); false } catch (_: AEADBadTagException) { true }
            check(rejected, "a tampered tag is rejected with AEADBadTagException")
        }
    }

    private fun cbcKey() {
        step("AES-CBC") {
            val kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            kg.init(KeyGenParameterSpec.Builder(SB_CBC,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_CBC)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_PKCS7)
                .setKeySize(128)
                .setIsStrongBoxBacked(true)
                .build())
            val key = kg.generateKey()
            check(levelOf(key) == KeyProperties.SECURITY_LEVEL_STRONGBOX,
                "generateKey, security level STRONGBOX")
            val pt = message(1000)
            val enc = Cipher.getInstance("AES/CBC/PKCS7Padding")
            enc.init(Cipher.ENCRYPT_MODE, key)
            val ct = enc.doFinal(pt)
            check(ct.size == 1008 && enc.iv?.size == 16,
                "encrypt 1000 bytes: 1008 out, 16-byte IV", "ct ${ct.size}")
            val dec = Cipher.getInstance("AES/CBC/PKCS7Padding")
            dec.init(Cipher.DECRYPT_MODE, key, IvParameterSpec(enc.iv))
            check(dec.doFinal(ct).contentEquals(pt), "decrypt round-trips")
        }
    }
}
