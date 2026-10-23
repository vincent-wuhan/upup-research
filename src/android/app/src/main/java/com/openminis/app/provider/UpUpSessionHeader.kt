package com.openminis.app.provider

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * Attach `x-upup-session` to requests bound for the UpUp gateway
 * (https://upup.yueming.xin, OpenAI-compatible).
 *
 * The gateway derives its server-side session key from a hash of the message
 * prefix, which is unstable across client retries (history recomputation can
 * drop orphaned tool parts, replace images with placeholders, or inject a
 * compaction summary). With this header it routes on the conversation UUID
 * instead, so a retry or provider fallback keeps the same server session.
 *
 * Mirrors [OpenCodeSessionHeader]: same persisted-id guard ([isPersistedSessionId]),
 * same host-equality gate so the id is never handed to third-party endpoints.
 */
object UpUpSessionHeader {

    /** The header the UpUp gateway routes on. */
    const val HEADER = "x-upup-session"

    /** Host of the UpUp gateway. Matched exactly or as a dot-anchored subdomain. */
    private const val HOST = "upup.yueming.xin"

    fun matches(baseUrl: String?): Boolean {
        val raw = baseUrl?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        val normalized = if (raw.contains("://")) raw else "https://$raw"
        val host = normalized.toHttpUrlOrNull()?.host ?: return false
        return host == HOST || host.endsWith(".$HOST")
    }

    fun headersFor(baseUrl: String?, sessionId: String?): Map<String, String> {
        if (!matches(baseUrl)) return emptyMap()
        val id = sessionId?.trim().orEmpty()
        if (!OpenCodeSessionHeader.isPersistedSessionId(id)) return emptyMap()
        return mapOf(HEADER to id)
    }
}
