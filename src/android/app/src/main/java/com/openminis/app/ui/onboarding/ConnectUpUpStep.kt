package com.openminis.app.ui.onboarding

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.openminis.app.R
import com.openminis.app.data.model.LLMModel
import com.openminis.app.data.model.ModelEntry
import com.openminis.app.data.model.ModelGroup
import com.openminis.app.data.model.ProviderCredential
import com.openminis.app.data.model.ProviderInstance
import com.openminis.app.data.model.ProviderType
import com.openminis.app.data.repository.ProviderRepository
import com.openminis.app.ui.components.MinisButton
import com.openminis.app.ui.components.MinisTextButton
import com.openminis.app.ui.components.RowLabel
import com.openminis.app.ui.components.SectionTextField
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import java.util.concurrent.TimeUnit

/**
 * [T-upup-connect-step] 首启「连接涨涨网关」。
 *
 * 目标形态：装完即用，零配置。用户只填两样东西——网关地址与访问密钥，
 * 点一次「连接」，App 就把 provider、三个场景模型、默认模型组一次写好，
 * 直接进对话；不需要再进设置页手动补 base URL、补模型。
 *
 * 校验方式：GET {base}/v1/models + Bearer。200 即视为地址可达且密钥有效。
 * 这里刻意不依赖 /models 的返回内容：upup gateway 的 /v1/models 返回的是
 * 场景清单（created=0 的极简条目），既不能作为可用模型的来源，也不该
 * 被当作「登录成功」的判据。三个场景模型由本步显式写入。
 */
private val UPUP_SCENE_MODELS = listOf(
    "upup-chat" to "涨涨对话",
    "upup-invest" to "涨涨投研",
    "upup-brief" to "涨涨简报",
)

private const val UPUP_DEFAULT_GATEWAY = "https://upup.yueming.xin"
private const val UPUP_INSTANCE_ID = "upup_gateway"

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConnectUpUpStep(
    providerRepository: ProviderRepository,
    onComplete: () -> Unit,
    onUseOtherProvider: () -> Unit,
) {
    var baseUrl by remember { mutableStateOf(UPUP_DEFAULT_GATEWAY) }
    var apiKey by remember { mutableStateOf("") }
    var connecting by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }

    val titleText = stringResource(R.string.upup_connect_title)
    val subtitleText = stringResource(R.string.upup_connect_subtitle)
    val gatewayLabel = stringResource(R.string.upup_connect_gateway_label)
    val keyLabel = stringResource(R.string.upup_connect_key_label)
    val keyHint = stringResource(R.string.upup_connect_key_hint)
    val actionText = stringResource(R.string.upup_connect_action)
    val useOtherText = stringResource(R.string.upup_connect_use_other)
    val providerLabel = stringResource(R.string.upup_connect_provider_label)
    val groupName = stringResource(R.string.upup_connect_group_name)
    val missingText = stringResource(R.string.upup_connect_error_missing)

    val scope = rememberCoroutineScope()

    Scaffold { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .padding(24.dp),
        ) {
            Text(
                titleText,
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.Bold,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                subtitleText,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Spacer(Modifier.height(24.dp))

            RowLabel(text = gatewayLabel)
            SectionTextField(
                value = baseUrl,
                onValueChange = { baseUrl = it; errorMessage = null },
                singleLine = true,
                placeholder = UPUP_DEFAULT_GATEWAY,
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
            )
            Spacer(Modifier.height(16.dp))

            RowLabel(text = keyLabel)
            SectionTextField(
                value = apiKey,
                onValueChange = { apiKey = it; errorMessage = null },
                singleLine = true,
                placeholder = "upup-...",
                textStyle = MaterialTheme.typography.bodyMedium.copy(fontFamily = FontFamily.Monospace),
                visualTransformation = PasswordVisualTransformation(),
            )
            Spacer(Modifier.height(8.dp))
            Text(
                keyHint,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            val currentError = errorMessage
            if (currentError != null) {
                Spacer(Modifier.height(16.dp))
                Text(
                    currentError,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            }

            Spacer(Modifier.height(28.dp))

            MinisButton(
                onClick = {
                    val base = baseUrl.trim().trimEnd('/')
                    val key = apiKey.trim()
                    if (base.isBlank() || key.isBlank()) {
                        errorMessage = missingText
                        return@MinisButton
                    }
                    connecting = true
                    errorMessage = null
                    scope.launch {
                        val failure = withContext(Dispatchers.IO) { probeGateway(base, key) }
                        if (failure != null) {
                            errorMessage = failure
                            connecting = false
                            return@launch
                        }
                        providerRepository.addInstance(
                            ProviderInstance(
                                id = UPUP_INSTANCE_ID,
                                label = providerLabel,
                                providerType = ProviderType.openAI,
                                credentialType = ProviderCredential.apiKey,
                            ).apply {
                                customBaseURL = base
                                appendV1Suffix = true
                                useResponsesAPI = false
                            },
                        )
                        providerRepository.saveApiKey(UPUP_INSTANCE_ID, key)

                        val entryIds = UPUP_SCENE_MODELS.map { (modelId, displayName) ->
                            val entry = ModelEntry(
                                providerInstanceId = UPUP_INSTANCE_ID,
                                baseModel = LLMModel(
                                    id = modelId,
                                    displayName = displayName,
                                    provider = ProviderType.openAI.displayName,
                                ),
                                isCustom = true,
                            )
                            providerRepository.addEntry(entry)
                            entry.uuid
                        }

                        val group = ModelGroup(name = groupName)
                        group.memberEntryIds.addAll(entryIds)
                        providerRepository.addGroup(group)
                        if (providerRepository.defaultPrimaryGroupId == null) {
                            providerRepository.defaultPrimaryGroupId = group.id
                        }
                        connecting = false
                        onComplete()
                    }
                },
                enabled = !connecting,
                modifier = Modifier.fillMaxWidth(),
            ) {
                if (connecting) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                        color = MaterialTheme.colorScheme.onPrimary,
                    )
                } else {
                    Text(actionText)
                }
            }

            Spacer(Modifier.weight(1f))

            MinisTextButton(
                onClick = onUseOtherProvider,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(useOtherText, textAlign = TextAlign.Center)
            }
        }
    }
}

/**
 * 校验网关：GET {base}/v1/models + Bearer。返回 null 表示通过，否则返回
 * 面向用户的错误文案。
 */
private fun probeGateway(base: String, key: String): String? {
    val url = if (base.endsWith("/v1")) "$base/models" else "$base/v1/models"
    val client = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()
    val request = Request.Builder()
        .url(url)
        .header("Authorization", "Bearer $key")
        .build()
    return try {
        client.newCall(request).execute().use { response ->
            when {
                response.code == 401 || response.code == 403 -> "密钥无效或已失效"
                !response.isSuccessful -> "网关返回 HTTP ${response.code}"
                else -> null
            }
        }
    } catch (e: Exception) {
        "无法连接网关：${e.message?.takeIf { it.isNotBlank() } ?: e.javaClass.simpleName}"
    }
}
