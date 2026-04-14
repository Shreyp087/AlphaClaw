package com.meta.wearable.dat.externalsampleapps.cameraaccess.conference

import com.google.gson.JsonElement
import com.google.gson.JsonParser
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
                val json = JsonParser.parseString(jsonText).asJsonObject
                ConferenceEnrichmentPayload(
                    headline = readString(json.get("headline")),
                    companySummary = readString(json.get("company_summary")),
                    talkingPoints = readStringArray(json.get("talking_points")),
                    followUp = readString(json.get("follow_up")),
                    confidenceNotes = readString(json.get("confidence_notes")),
                    sourceUrls = readStringArray(json.get("source_urls")),
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

        private fun readString(element: JsonElement?): String? {
            if (element == null || element.isJsonNull || !element.isJsonPrimitive) return null
            val value = element.asString.trim()
            return value.takeIf { it.isNotEmpty() }
        }

        private fun readStringArray(element: JsonElement?): List<String> {
            if (element == null || element.isJsonNull || !element.isJsonArray) return emptyList()
            return element.asJsonArray.mapNotNull { item ->
                if (item == null || item.isJsonNull || !item.isJsonPrimitive) {
                    null
                } else {
                    item.asString.trim().takeIf { it.isNotEmpty() }
                }
            }
        }
    }
}
