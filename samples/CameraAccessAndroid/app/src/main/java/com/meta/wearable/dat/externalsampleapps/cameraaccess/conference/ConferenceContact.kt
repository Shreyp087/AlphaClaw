package com.meta.wearable.dat.externalsampleapps.cameraaccess.conference

enum class ConferenceEnrichmentStatus(val wireValue: String) {
    NOT_REQUESTED("notRequested"),
    QUEUED("queued"),
    ENRICHING("enriching"),
    COMPLETED("completed"),
    FAILED("failed");

    val displayName: String
        get() = when (this) {
            NOT_REQUESTED -> "Not Requested"
            QUEUED -> "Queued"
            ENRICHING -> "Enriching"
            COMPLETED -> "Enriched"
            FAILED -> "Needs Retry"
        }

    companion object {
        fun fromValue(value: String?): ConferenceEnrichmentStatus {
            return entries.firstOrNull { it.wireValue == value } ?: NOT_REQUESTED
        }
    }
}

data class ConferenceEnrichmentPayload(
    val headline: String? = null,
    val companySummary: String? = null,
    val talkingPoints: List<String> = emptyList(),
    val followUp: String? = null,
    val confidenceNotes: String? = null,
    val sourceUrls: List<String> = emptyList(),
    val rawResponse: String? = null,
) {
    val summaryText: String
        get() = listOfNotNull(headline, companySummary, followUp)
            .map { it.trim() }
            .filter { it.isNotEmpty() }
            .joinToString(separator = "\n\n")
}

data class ConferenceContact(
    val id: String,
    val dedupeKey: String,
    val name: String,
    val company: String?,
    val role: String?,
    val sourceType: ConferenceSourceType,
    val confidence: Double,
    val observedText: String?,
    val disposition: ConferenceExtractionDisposition,
    val firstSeenAtMs: Long,
    val lastSeenAtMs: Long,
    val enrichmentStatus: ConferenceEnrichmentStatus,
    val enrichment: ConferenceEnrichmentPayload?,
    val enrichmentError: String?,
    val lastEnrichedAtMs: Long?,
) {
    val summaryText: String
        get() = listOfNotNull(company?.trim()?.takeIf { it.isNotEmpty() }, role?.trim()?.takeIf { it.isNotEmpty() })
            .joinToString(separator = " / ")
}
