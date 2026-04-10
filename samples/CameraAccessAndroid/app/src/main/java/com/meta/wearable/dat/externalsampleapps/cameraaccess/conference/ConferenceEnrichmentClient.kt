package com.meta.wearable.dat.externalsampleapps.cameraaccess.conference

import com.meta.wearable.dat.externalsampleapps.cameraaccess.gemini.GeminiConfig
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.TimeUnit

class ConferenceEnrichmentClient(
    private val client: OkHttpClient = OkHttpClient.Builder()
        .readTimeout(120, TimeUnit.SECONDS)
        .connectTimeout(10, TimeUnit.SECONDS)
        .build(),
) {
    private val sessionKey = "agent:conference:networking"

    suspend fun enrich(contact: ConferenceContact): Result<ConferenceEnrichmentPayload> {
        if (!GeminiConfig.isOpenClawConfigured) {
            return Result.failure(IllegalStateException("OpenClaw is not configured"))
        }

        val url = "${GeminiConfig.openClawHost}:${GeminiConfig.openClawPort}/v1/chat/completions"
        val body = JSONObject().apply {
            put("model", "openclaw")
            put(
                "messages",
                JSONArray().put(
                    JSONObject().apply {
                        put("role", "user")
                        put("content", buildTask(contact))
                    },
                ),
            )
            put("stream", false)
        }

        val request = Request.Builder()
            .url(url)
            .post(body.toString().toRequestBody("application/json".toMediaType()))
            .addHeader("Authorization", "Bearer ${GeminiConfig.openClawGatewayToken}")
            .addHeader("Content-Type", "application/json")
            .addHeader("x-openclaw-session-key", sessionKey)
            .addHeader("x-openclaw-message-channel", "glass")
            .build()

        return runCatching {
            client.newCall(request).execute().use { response ->
                val rawBody = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    error("OpenClaw returned HTTP ${response.code}")
                }

                val content = JSONObject(rawBody)
                    .optJSONArray("choices")
                    ?.optJSONObject(0)
                    ?.optJSONObject("message")
                    ?.optString("content")
                    .orEmpty()

                parsePayload(content)
            }
        }
    }

    companion object {
        fun buildTask(contact: ConferenceContact): String {
            return """
                You are networking_autopilot, a relationship research assistant helping a conference attendee.

                Research the detected person or organization using any tools available to you and return ONLY a JSON object with this exact shape:
                {
                  "headline": "short one-line summary",
                  "company_summary": "what their company appears to do",
                  "talking_points": ["bullet one", "bullet two", "bullet three"],
                  "follow_up": "best follow-up angle or next step",
                  "confidence_notes": "what is solid vs inferred",
                  "source_urls": ["https://example.com"]
                }

                Rules:
                - Return valid JSON only. No markdown fences.
                - Use an empty string for unknown string fields.
                - Use an empty array for unknown list fields.
                - Be conservative when inferring details.

                Detected contact:
                - name: ${contact.name}
                - company: ${contact.company.orEmpty()}
                - role: ${contact.role.orEmpty()}
                - source_type: ${contact.sourceType.wireValue}
                - confidence: ${"%.2f".format(contact.confidence)}
                - observed_text: ${contact.observedText.orEmpty()}
            """.trimIndent()
        }

        fun parsePayload(response: String): ConferenceEnrichmentPayload {
            val trimmed = response.trim()
            val jsonText = extractJSONObject(trimmed) ?: trimmed
            return runCatching {
                val json = JSONObject(jsonText)
                ConferenceEnrichmentPayload(
                    headline = json.optString("headline").trim().takeIf { it.isNotEmpty() },
                    companySummary = json.optString("company_summary").trim().takeIf { it.isNotEmpty() },
                    talkingPoints = readStringArray(json.optJSONArray("talking_points")),
                    followUp = json.optString("follow_up").trim().takeIf { it.isNotEmpty() },
                    confidenceNotes = json.optString("confidence_notes").trim().takeIf { it.isNotEmpty() },
                    sourceUrls = readStringArray(json.optJSONArray("source_urls")),
                    rawResponse = trimmed,
                )
            }.getOrElse {
                ConferenceEnrichmentPayload(rawResponse = trimmed)
            }
        }

        private fun extractJSONObject(text: String): String? {
            val start = text.indexOf('{')
            val end = text.lastIndexOf('}')
            if (start == -1 || end == -1 || end <= start) return null
            return text.substring(start, end + 1)
        }

        private fun readStringArray(array: JSONArray?): List<String> {
            if (array == null) return emptyList()
            return buildList {
                for (index in 0 until array.length()) {
                    val value = array.optString(index).trim()
                    if (value.isNotEmpty()) {
                        add(value)
                    }
                }
            }
        }
    }
}
