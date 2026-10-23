package com.openminis.app.ui.settings

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.TrendingUp
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import com.openminis.app.data.repository.ProviderRepository
import com.openminis.app.provider.UpUpSessionHeader
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit

private data class UpupPanelData(
    val ticker: String?,
    val sop: String?,
    val planId: String?,
    val updatedAt: String?,
    val watchlist: List<Pair<String, String?>>,
    val plans: String?,
    val error: String? = null,
)

/**
 * Dossier / watchlist panel backed by the UpUp gateway's /api/upup endpoints
 * (same origin the chat provider uses). The gateway is resolved from the
 * first enabled OpenAI-compatible provider whose custom base URL points at
 * it (host-gated via [UpUpSessionHeader]), so no separate configuration.
 */
@Composable
fun UpupPanelScreen(
    providerRepository: ProviderRepository,
    onBack: () -> Unit,
) {
    val scope = rememberCoroutineScope()
    var data by remember { mutableStateOf<UpupPanelData?>(null) }
    var loading by remember { mutableStateOf(false) }

    fun load() {
        scope.launch {
            loading = true
            data = withContext(Dispatchers.IO) { fetchPanel(providerRepository) }
            loading = false
        }
    }

    androidx.compose.runtime.LaunchedEffect(Unit) { load() }

    SettingsScaffold(
        title = stringResource(R.string.upup_panel_title),
        onBack = onBack,
    ) {
        Column(modifier = Modifier.fillMaxWidth()) {
            SettingsSection(header = stringResource(R.string.upup_panel_state_section)) {
                val d = data
                when {
                    loading && d == null -> Text(
                        stringResource(R.string.upup_panel_loading),
                        modifier = Modifier.padding(16.dp),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    d?.error != null -> Text(
                        stringResource(R.string.upup_panel_error, d.error),
                        modifier = Modifier.padding(16.dp),
                        color = MaterialTheme.colorScheme.error,
                    )
                    d != null -> {
                        SettingsRow(
                            icon = Icons.Outlined.TrendingUp,
                            title = d.ticker ?: "—",
                            subtitle = listOfNotNull(
                                d.sop?.let { "SOP: $it" },
                                d.updatedAt?.let { it },
                            ).joinToString(" · ").ifEmpty { null },
                            onClick = {},
                            showDivider = false,
                        )
                    }
                    else -> {}
                }
            }

            SettingsSection(header = stringResource(R.string.upup_panel_watchlist_section)) {
                val entries = data?.watchlist.orEmpty()
                if (entries.isEmpty()) {
                    Text(
                        stringResource(R.string.upup_panel_watchlist_empty),
                        modifier = Modifier.padding(16.dp),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    entries.forEachIndexed { index, (symbol, note) ->
                        SettingsRow(
                            icon = Icons.Outlined.TrendingUp,
                            title = symbol,
                            subtitle = note,
                            onClick = {},
                            showDivider = index != entries.lastIndex,
                        )
                    }
                }
            }

            SettingsSection(header = stringResource(R.string.upup_panel_plans_section)) {
                val plans = data?.plans
                if (plans.isNullOrBlank()) {
                    Text(
                        stringResource(R.string.upup_panel_plans_empty),
                        modifier = Modifier.padding(16.dp),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else {
                    Text(
                        plans,
                        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
                        fontFamily = FontFamily.Monospace,
                        style = MaterialTheme.typography.bodySmall,
                    )
                }
            }

            SettingsSection(header = "") {
                SettingsRow(
                    icon = Icons.Outlined.Refresh,
                    title = stringResource(R.string.upup_panel_refresh),
                    subtitle = if (loading) stringResource(R.string.upup_panel_loading) else null,
                    onClick = { load() },
                    showDivider = false,
                )
            }
        }
    }
}

private fun fetchPanel(providerRepository: ProviderRepository): UpupPanelData {
    val config = providerRepository.config.value
    val instance = config.instances.firstOrNull {
        it.isEnabled && UpUpSessionHeader.matches(it.customBaseURL)
    } ?: return UpupPanelData(null, null, null, null, emptyList(), null,
        error = "no UpUp gateway provider")

    val base = instance.customBaseURL!!.trim().let { raw ->
        val withScheme = if (raw.contains("://")) raw else "https://$raw"
        val afterScheme = withScheme.substringAfter("://")
        "https://" + afterScheme.substringBefore('/')
    }
    val key = providerRepository.loadApiKey(instance.id) ?: return UpupPanelData(
        null, null, null, null, emptyList(), null, error = "no API key")

    val client = OkHttpClient.Builder().callTimeout(30, TimeUnit.SECONDS).build()
    fun call(path: String, method: String = "GET"): JSONObject? {
        val request = Request.Builder()
            .url("$base$path")
            .method(method, if (method == "POST") okhttp3.RequestBody.create(null, ByteArray(0)) else null)
            .header("Authorization", "Bearer $key")
            .build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) return null
            val text = response.body?.string() ?: return null
            return JSONObject(text)
        }
    }

    return try {
        val state = call("/api/upup/state")
        val watchlistJson = call("/api/upup/watchlist")
        val plans = call("/api/upup/run/--list", "POST")

        val watchlist = mutableListOf<Pair<String, String?>>()
        val entries = watchlistJson?.optJSONObject("watchlist")?.optJSONObject("entries")
        entries?.keys()?.forEach { symbol ->
            val entry = entries.optJSONObject(symbol)
            watchlist.add(symbol to entry?.optString("note")?.takeIf { it.isNotBlank() })
        }

        UpupPanelData(
            ticker = state?.optString("ticker")?.takeIf { it.isNotEmpty() && it != "null" },
            sop = state?.optString("sop")?.takeIf { it.isNotEmpty() && it != "null" },
            planId = state?.optString("planId")?.takeIf { it.isNotEmpty() && it != "null" },
            updatedAt = state?.optString("updatedAt")?.takeIf { it.isNotEmpty() && it != "null" },
            watchlist = watchlist,
            plans = plans?.optString("result")?.takeIf { it.isNotBlank() },
        )
    } catch (err: Exception) {
        UpupPanelData(null, null, null, null, emptyList(), null, error = err.message ?: "network error")
    }
}
