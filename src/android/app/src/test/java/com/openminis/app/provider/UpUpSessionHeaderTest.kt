package com.openminis.app.provider

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [UpUpSessionHeader] Who receives `x-upup-session`, and with what value.
 *
 * The UpUp gateway routes its server-side session on this header so retries
 * and provider fallbacks (which recompute the outbound history) keep landing
 * in the same session. Pins the same two silent failure modes as
 * [OpenCodeSessionHeaderTest]: leaking the id to a non-gateway host, and
 * emitting a draft placeholder that turns into a real UUID after turn one.
 */
class UpUpSessionHeaderTest {

    private val SID = "3f2a1c7e-9b04-4d55-8e21-0a7c6f5b3d19"
    private val URL = "https://upup.yueming.xin/v1"

    // ── Host gating ───────────────────────────────────────────────────────

    @Test
    fun `the gateway host is matched`() {
        assertTrue(UpUpSessionHeader.matches(URL))
        assertTrue(UpUpSessionHeader.matches("upup.yueming.xin/v1"))
        assertTrue(UpUpSessionHeader.matches("http://upup.yueming.xin/v1"))
    }

    @Test
    fun `subdomains of the gateway are matched`() {
        assertTrue(UpUpSessionHeader.matches("https://api.upup.yueming.xin/v1"))
    }

    @Test
    fun `lookalike hosts are not matched`() {
        assertFalse(UpUpSessionHeader.matches("https://upup.yueming.xin.evil.example.com/v1"))
        assertFalse(UpUpSessionHeader.matches("https://not-upup.yueming.xin/v1"))
        assertFalse(UpUpSessionHeader.matches("https://relay.example.com/upup.yueming.xin/v1"))
    }

    @Test
    fun `ordinary providers and absent urls are not matched`() {
        for (url in listOf(
            "https://api.openai.com/v1",
            "https://opencode.ai/zen/go/v1",
            "http://192.168.1.10:11434/v1",
        )) {
            assertFalse("$url must not match", UpUpSessionHeader.matches(url))
        }
        assertFalse(UpUpSessionHeader.matches(null))
        assertFalse(UpUpSessionHeader.matches("not a url"))
    }

    // ── Header emission ───────────────────────────────────────────────────

    @Test
    fun `a matched host with a real session id gets the header`() {
        assertEquals(mapOf("x-upup-session" to SID), UpUpSessionHeader.headersFor(URL, SID))
    }

    @Test
    fun `an unmatched host never gets the header`() {
        assertTrue(UpUpSessionHeader.headersFor("https://api.openai.com/v1", SID).isEmpty())
    }

    @Test
    fun `a draft session id is never sent`() {
        assertTrue(UpUpSessionHeader.headersFor(URL, "__new__$SID").isEmpty())
        assertTrue(UpUpSessionHeader.headersFor(URL, "__new__abc__fld__work").isEmpty())
    }

    @Test
    fun `a missing or blank id sends nothing`() {
        assertTrue(UpUpSessionHeader.headersFor(URL, null).isEmpty())
        assertTrue(UpUpSessionHeader.headersFor(URL, "   ").isEmpty())
    }

    @Test
    fun `a padded id is trimmed rather than refused`() {
        assertEquals(mapOf("x-upup-session" to SID), UpUpSessionHeader.headersFor(URL, "  $SID  "))
    }

    @Test
    fun `different sessions yield different headers`() {
        val a = UpUpSessionHeader.headersFor(URL, "aaaaaaaa-0000-0000-0000-000000000001")
        val b = UpUpSessionHeader.headersFor(URL, "bbbbbbbb-0000-0000-0000-000000000002")
        assertTrue(a.isNotEmpty() && a != b)
    }

    @Test
    fun `the header name is part of the gateway contract`() {
        assertEquals("x-upup-session", UpUpSessionHeader.HEADER)
    }
}
