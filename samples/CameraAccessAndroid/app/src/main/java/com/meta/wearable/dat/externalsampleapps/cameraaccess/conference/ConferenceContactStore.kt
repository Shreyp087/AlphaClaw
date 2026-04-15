package com.meta.wearable.dat.externalsampleapps.cameraaccess.conference

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import java.util.UUID

object ConferenceContactStore {
    private const val DATABASE_NAME = "conference_contacts.db"
    private const val DATABASE_VERSION = 2
    private const val TABLE_NAME = "conference_contacts"

    private lateinit var helper: ConferenceContactDbHelper
    private val gson = Gson()

    fun init(context: Context) {
        if (!::helper.isInitialized) {
            helper = ConferenceContactDbHelper(context.applicationContext)
        }
    }

    @Synchronized
    fun fetchContacts(limit: Int = 100): List<ConferenceContact> {
        if (!::helper.isInitialized) return emptyList()
        val db = helper.readableDatabase
        val cursor = db.query(
            TABLE_NAME,
            null,
            null,
            null,
            null,
            null,
            "COALESCE(last_conversation_at_ms, last_seen_at_ms) DESC, last_seen_at_ms DESC",
            limit.toString(),
        )

        cursor.use {
            val results = mutableListOf<ConferenceContact>()
            while (it.moveToNext()) {
                readContact(it)?.let(results::add)
            }
            return results
        }
    }

    @Synchronized
    fun fetchContact(id: String): ConferenceContact? {
        if (!::helper.isInitialized) return null
        val db = helper.readableDatabase
        val cursor = db.query(
            TABLE_NAME,
            null,
            "id = ?",
            arrayOf(id),
            null,
            null,
            null,
            "1",
        )

        cursor.use {
            if (!it.moveToFirst()) return null
            return readContact(it)
        }
    }

    @Synchronized
    fun upsert(extraction: ConferenceExtraction): ConferenceContact? {
        if (!::helper.isInitialized) return null
        val db = helper.writableDatabase
        val dedupeKey = ConferenceExtractionProcessor.normalizedKey(
            extraction.name,
            extraction.company,
            extraction.sourceType,
        )

        val existing = fetchByDedupeKey(db, dedupeKey)
        val contact = if (existing != null) {
            existing.copy(
                company = extraction.company ?: existing.company,
                role = extraction.role ?: existing.role,
                confidence = maxOf(existing.confidence, extraction.confidence),
                observedText = extraction.observedText ?: existing.observedText,
                disposition = if (
                    existing.disposition == ConferenceExtractionDisposition.ACCEPTED ||
                    extraction.disposition == ConferenceExtractionDisposition.ACCEPTED
                ) {
                    ConferenceExtractionDisposition.ACCEPTED
                } else {
                    ConferenceExtractionDisposition.REVIEW
                },
                lastSeenAtMs = extraction.detectedAtMs,
            )
        } else {
            ConferenceContact(
                id = UUID.randomUUID().toString(),
                dedupeKey = dedupeKey,
                name = extraction.name,
                company = extraction.company,
                role = extraction.role,
                sourceType = extraction.sourceType,
                confidence = extraction.confidence,
                observedText = extraction.observedText,
                disposition = extraction.disposition,
                firstSeenAtMs = extraction.detectedAtMs,
                lastSeenAtMs = extraction.detectedAtMs,
                enrichmentStatus = ConferenceEnrichmentStatus.NOT_REQUESTED,
                enrichment = null,
                enrichmentError = null,
                lastEnrichedAtMs = null,
                conversationSnippet = null,
                lastConversationAtMs = null,
            )
        }

        save(db, contact)
        return contact
    }

    @Synchronized
    fun queueEnrichmentIfNeeded(contactId: String): Boolean {
        val existing = fetchContact(contactId) ?: return false
        if (existing.disposition != ConferenceExtractionDisposition.ACCEPTED) return false
        if (
            existing.enrichmentStatus != ConferenceEnrichmentStatus.NOT_REQUESTED &&
            existing.enrichmentStatus != ConferenceEnrichmentStatus.FAILED
        ) {
            return false
        }

        save(
            helper.writableDatabase,
            existing.copy(enrichmentStatus = ConferenceEnrichmentStatus.QUEUED, enrichmentError = null),
        )
        return true
    }

    @Synchronized
    fun markEnrichmentRunning(contactId: String) {
        updateStatus(contactId, ConferenceEnrichmentStatus.ENRICHING, null)
    }

    @Synchronized
    fun completeEnrichment(contactId: String, payload: ConferenceEnrichmentPayload, completedAtMs: Long = System.currentTimeMillis()) {
        val existing = fetchContact(contactId) ?: return
        save(
            helper.writableDatabase,
            existing.copy(
                enrichmentStatus = ConferenceEnrichmentStatus.COMPLETED,
                enrichment = payload,
                enrichmentError = null,
                lastEnrichedAtMs = completedAtMs,
            ),
        )
    }

    @Synchronized
    fun failEnrichment(contactId: String, error: String) {
        updateStatus(contactId, ConferenceEnrichmentStatus.FAILED, error)
    }

    @Synchronized
    fun appendConversationSnippet(contactId: String, snippet: String, observedAtMs: Long = System.currentTimeMillis()) {
        val cleanedSnippet = snippet.trim()
        if (cleanedSnippet.isEmpty()) return

        val existing = fetchContact(contactId) ?: return
        save(
            helper.writableDatabase,
            existing.copy(
                conversationSnippet = mergeConversationSnippet(existing.conversationSnippet, cleanedSnippet),
                lastConversationAtMs = observedAtMs,
            ),
        )
    }

    private fun updateStatus(contactId: String, status: ConferenceEnrichmentStatus, error: String?) {
        val existing = fetchContact(contactId) ?: return
        save(
            helper.writableDatabase,
            existing.copy(enrichmentStatus = status, enrichmentError = error),
        )
    }

    private fun save(db: SQLiteDatabase, contact: ConferenceContact) {
        db.insertWithOnConflict(
            TABLE_NAME,
            null,
            ContentValues().apply {
                put("id", contact.id)
                put("dedupe_key", contact.dedupeKey)
                put("name", contact.name)
                put("company", contact.company)
                put("role", contact.role)
                put("source_type", contact.sourceType.wireValue)
                put("confidence", contact.confidence)
                put("observed_text", contact.observedText)
                put("disposition", contact.disposition.wireValue)
                put("first_seen_at_ms", contact.firstSeenAtMs)
                put("last_seen_at_ms", contact.lastSeenAtMs)
                put("enrichment_status", contact.enrichmentStatus.wireValue)
                put("enrichment_json", contact.enrichment?.let(gson::toJson))
                put("enrichment_error", contact.enrichmentError)
                put("last_enriched_at_ms", contact.lastEnrichedAtMs)
                put("conversation_snippet", contact.conversationSnippet)
                put("last_conversation_at_ms", contact.lastConversationAtMs)
            },
            SQLiteDatabase.CONFLICT_REPLACE,
        )
    }

    private fun fetchByDedupeKey(db: SQLiteDatabase, dedupeKey: String): ConferenceContact? {
        val cursor = db.query(
            TABLE_NAME,
            null,
            "dedupe_key = ?",
            arrayOf(dedupeKey),
            null,
            null,
            null,
            "1",
        )

        cursor.use {
            if (!it.moveToFirst()) return null
            return readContact(it)
        }
    }

    private fun readContact(cursor: android.database.Cursor): ConferenceContact? {
        val sourceType = ConferenceSourceType.fromValue(cursor.getString(cursor.getColumnIndexOrThrow("source_type"))) ?: return null
        val disposition = ConferenceExtractionDisposition.entries.firstOrNull {
            it.wireValue == cursor.getString(cursor.getColumnIndexOrThrow("disposition"))
        } ?: return null
        val enrichmentJson = cursor.getString(cursor.getColumnIndexOrThrow("enrichment_json"))
        val enrichmentPayload = if (!enrichmentJson.isNullOrBlank()) {
            gson.fromJson<ConferenceEnrichmentPayload>(enrichmentJson, object : TypeToken<ConferenceEnrichmentPayload>() {}.type)
        } else {
            null
        }

        return ConferenceContact(
            id = cursor.getString(cursor.getColumnIndexOrThrow("id")),
            dedupeKey = cursor.getString(cursor.getColumnIndexOrThrow("dedupe_key")),
            name = cursor.getString(cursor.getColumnIndexOrThrow("name")),
            company = cursor.getString(cursor.getColumnIndexOrThrow("company")),
            role = cursor.getString(cursor.getColumnIndexOrThrow("role")),
            sourceType = sourceType,
            confidence = cursor.getDouble(cursor.getColumnIndexOrThrow("confidence")),
            observedText = cursor.getString(cursor.getColumnIndexOrThrow("observed_text")),
            disposition = disposition,
            firstSeenAtMs = cursor.getLong(cursor.getColumnIndexOrThrow("first_seen_at_ms")),
            lastSeenAtMs = cursor.getLong(cursor.getColumnIndexOrThrow("last_seen_at_ms")),
            enrichmentStatus = ConferenceEnrichmentStatus.fromValue(cursor.getString(cursor.getColumnIndexOrThrow("enrichment_status"))),
            enrichment = enrichmentPayload,
            enrichmentError = cursor.getString(cursor.getColumnIndexOrThrow("enrichment_error")),
            lastEnrichedAtMs = if (cursor.isNull(cursor.getColumnIndexOrThrow("last_enriched_at_ms"))) {
                null
            } else {
                cursor.getLong(cursor.getColumnIndexOrThrow("last_enriched_at_ms"))
            },
            conversationSnippet = cursor.getString(cursor.getColumnIndexOrThrow("conversation_snippet")),
            lastConversationAtMs = if (cursor.isNull(cursor.getColumnIndexOrThrow("last_conversation_at_ms"))) {
                null
            } else {
                cursor.getLong(cursor.getColumnIndexOrThrow("last_conversation_at_ms"))
            },
        )
    }

    fun mergeConversationSnippet(existing: String?, newSnippet: String, maxCharacters: Int = 1200): String {
        val cleanedNewSnippet = newSnippet.trim()
        if (cleanedNewSnippet.isEmpty()) return existing?.trim().orEmpty()

        val cleanedExisting = existing?.trim().orEmpty()
        val merged = when {
            cleanedExisting.isEmpty() -> cleanedNewSnippet
            cleanedExisting.contains(cleanedNewSnippet) -> cleanedExisting
            else -> "$cleanedExisting\n\n$cleanedNewSnippet"
        }

        if (merged.length <= maxCharacters) return merged
        return merged.takeLast(maxCharacters).trim()
    }

    private class ConferenceContactDbHelper(context: Context) :
        SQLiteOpenHelper(context, DATABASE_NAME, null, DATABASE_VERSION) {

        override fun onCreate(db: SQLiteDatabase) {
            db.execSQL(
                """
                CREATE TABLE IF NOT EXISTS $TABLE_NAME (
                    id TEXT PRIMARY KEY NOT NULL,
                    dedupe_key TEXT NOT NULL UNIQUE,
                    name TEXT NOT NULL,
                    company TEXT,
                    role TEXT,
                    source_type TEXT NOT NULL,
                    confidence REAL NOT NULL,
                    observed_text TEXT,
                    disposition TEXT NOT NULL,
                    first_seen_at_ms INTEGER NOT NULL,
                    last_seen_at_ms INTEGER NOT NULL,
                    enrichment_status TEXT NOT NULL,
                    enrichment_json TEXT,
                    enrichment_error TEXT,
                    last_enriched_at_ms INTEGER,
                    conversation_snippet TEXT,
                    last_conversation_at_ms INTEGER
                )
                """.trimIndent(),
            )
        }

        override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
            if (oldVersion < 2) {
                db.execSQL("ALTER TABLE $TABLE_NAME ADD COLUMN conversation_snippet TEXT")
                db.execSQL("ALTER TABLE $TABLE_NAME ADD COLUMN last_conversation_at_ms INTEGER")
            }
        }
    }
}
