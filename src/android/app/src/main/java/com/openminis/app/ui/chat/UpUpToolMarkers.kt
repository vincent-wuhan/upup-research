package com.openminis.app.ui.chat

/**
 * Server-side tool activity markers embedded in the chat stream by the UpUp
 * gateway (⟪upup-tool:start|name⟫ / ⟪upup-tool:end|name|ok⟫) and upgraded to
 * native tool cards in the agent loop. The gateway emits each marker as a
 * standalone text delta; [extract] only claims a chunk whose entire content
 * is marker line(s) so real reply text is never swallowed.
 */
object UpUpToolMarkers {

    data class Marker(val action: String, val name: String, val ok: Boolean?)

    private val LINE = Regex("⟪upup-tool:(start|end)\\|([^|⟫\\n]+)(?:\\|([^⟫\\n]*))?⟫")

    fun extract(text: String): List<Marker>? {
        if (!text.contains("⟪upup-tool:")) return null
        val matches = LINE.findAll(text).toList()
        if (matches.isEmpty()) return null
        val residue = LINE.replace(text, "").trim()
        if (residue.isNotEmpty()) return null
        return matches.map { m ->
            Marker(
                action = m.groupValues[1],
                name = m.groupValues[2],
                ok = when (m.groupValues[3]) {
                    "ok" -> true
                    "failed" -> false
                    else -> null
                },
            )
        }
    }
}
