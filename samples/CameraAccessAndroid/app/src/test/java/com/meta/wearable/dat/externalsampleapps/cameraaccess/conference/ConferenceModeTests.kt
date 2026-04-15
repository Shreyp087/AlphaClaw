package com.meta.wearable.dat.externalsampleapps.cameraaccess.conference

import com.meta.wearable.dat.externalsampleapps.cameraaccess.openclaw.ToolDeclarations
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConferenceModeTests {

    @Test
    fun conferencePromptUsesFallbackWhenDisabled() {
        val fallback = "custom prompt"

        assertEquals(
            fallback,
            ConferencePrompts.activeSystemInstruction(
                conferenceModeEnabled = false,
                fallbackPrompt = fallback,
            ),
        )
    }

    @Test
    fun conferencePromptUsesRelationshipOpsWhenEnabled() {
        assertEquals(
            ConferencePrompts.relationshipOps,
            ConferencePrompts.activeSystemInstruction(
                conferenceModeEnabled = true,
                fallbackPrompt = "custom",
            ),
        )
    }

    @Test
    fun toolDeclarationsExcludeExtractEntityWhenConferenceModeDisabled() {
        val names = ToolDeclarations.allDeclarations(conferenceModeEnabled = false).map { it.name }

        assertEquals(listOf(ToolDeclarations.EXECUTE_NAME), names)
    }

    @Test
    fun toolDeclarationsIncludeExtractEntityWhenConferenceModeEnabled() {
        val names = ToolDeclarations.allDeclarations(conferenceModeEnabled = true).map { it.name }

        assertEquals(
            listOf(ToolDeclarations.EXECUTE_NAME, ToolDeclarations.EXTRACT_ENTITY_NAME),
            names,
        )
    }

    @Test
    fun processorAcceptsHighConfidenceExtraction() {
        val processor = makeProcessor()

        val result = processor.handle(
            args = mapOf(
                "name" to "Sarah Chen",
                "company" to "Acme AI",
                "role" to "VP Engineering",
                "source_type" to "badge",
                "confidence" to 0.92,
            ),
            nowMs = 0L,
        )

        assertTrue(result is ConferenceExtractionHandlingResult.Accepted)
        val extraction = (result as ConferenceExtractionHandlingResult.Accepted).extraction
        assertEquals("Sarah Chen", extraction.name)
        assertEquals(ConferenceSourceType.BADGE, extraction.sourceType)
        assertEquals(ConferenceExtractionDisposition.ACCEPTED, extraction.disposition)
    }

    @Test
    fun processorReturnsReviewForMidConfidenceExtraction() {
        val processor = makeProcessor()

        val result = processor.handle(
            args = mapOf(
                "name" to "Taylor Reed",
                "source_type" to "card",
                "confidence" to 0.61,
            ),
            nowMs = 0L,
        )

        assertTrue(result is ConferenceExtractionHandlingResult.Review)
        val extraction = (result as ConferenceExtractionHandlingResult.Review).extraction
        assertEquals(ConferenceExtractionDisposition.REVIEW, extraction.disposition)
        assertEquals(ConferenceSourceType.CARD, extraction.sourceType)
    }

    @Test
    fun processorIgnoresLowConfidenceExtraction() {
        val processor = makeProcessor()

        val result = processor.handle(
            args = mapOf(
                "name" to "Jamie Park",
                "source_type" to "booth",
                "confidence" to 0.32,
            ),
            nowMs = 0L,
        )

        assertTrue(result is ConferenceExtractionHandlingResult.IgnoredLowConfidence)
        val confidence = (result as ConferenceExtractionHandlingResult.IgnoredLowConfidence).confidence
        assertEquals(0.32, confidence, 0.0001)
    }

    @Test
    fun processorSuppressesDuplicatesWithinCooldown() {
        val processor = makeProcessor()
        val args = mapOf(
            "name" to "Morgan Lee",
            "company" to "OpenClaw",
            "source_type" to "badge",
            "confidence" to 0.88,
        )

        val firstResult = processor.handle(args = args, nowMs = 0L)
        assertTrue(firstResult is ConferenceExtractionHandlingResult.Accepted)

        val secondResult = processor.handle(args = args, nowMs = 5_000L)
        assertEquals(ConferenceExtractionHandlingResult.IgnoredDuplicate, secondResult)
    }

    @Test
    fun enrichmentParserExtractsStructuredPayload() {
        val response = """
            Here is the result:
            {"headline":"AI founder building wearable copilots","company_summary":"Northstar Labs builds AI workflow tools.","talking_points":["Ask about conference demos","Mention wearable UX"],"follow_up":"Send a short intro after the event.","confidence_notes":"Role is explicit; company details inferred.","source_urls":["https://northstar.example.com"]}
        """.trimIndent()

        val payload = ConferenceEnrichmentClient.parsePayload(response)

        assertEquals("AI founder building wearable copilots", payload.headline)
        assertEquals(2, payload.talkingPoints.size)
        assertEquals(1, payload.sourceUrls.size)
    }

    @Test
    fun enrichmentTaskIncludesDetectedContactFields() {
        val contact = ConferenceContact(
            id = "1",
            dedupeKey = "alex|openai|badge",
            name = "Alex Morgan",
            company = "OpenAI",
            role = "Researcher",
            sourceType = ConferenceSourceType.BADGE,
            confidence = 0.88,
            observedText = "Alex Morgan OpenAI",
            disposition = ConferenceExtractionDisposition.ACCEPTED,
            firstSeenAtMs = 1L,
            lastSeenAtMs = 1L,
            enrichmentStatus = ConferenceEnrichmentStatus.NOT_REQUESTED,
            enrichment = null,
            enrichmentError = null,
            lastEnrichedAtMs = null,
            conversationSnippet = null,
            lastConversationAtMs = null,
        )

        val task = ConferenceEnrichmentClient.buildTask(contact)

        assertTrue(task.contains("Alex Morgan"))
        assertTrue(task.contains("OpenAI"))
        assertTrue(task.contains("Researcher"))
        assertTrue(task.contains("badge"))
    }

    @Test
    fun conversationSnippetMergeAvoidsDuplicateAppend() {
        val merged = ConferenceContactStore.mergeConversationSnippet(
            existing = "User: Hello there",
            newSnippet = "User: Hello there",
        )

        assertEquals("User: Hello there", merged)
    }

    private fun makeProcessor(): ConferenceExtractionProcessor {
        return ConferenceExtractionProcessor(
            ConferenceModeConfig(
                enabled = true,
                acceptedConfidenceMin = 0.70,
                reviewConfidenceMin = 0.50,
                duplicateCooldownMs = 10_000L,
            ),
        )
    }
}
