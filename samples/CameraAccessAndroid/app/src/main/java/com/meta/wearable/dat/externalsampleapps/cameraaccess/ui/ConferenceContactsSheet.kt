package com.meta.wearable.dat.externalsampleapps.cameraaccess.ui

import android.text.format.DateUtils
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.meta.wearable.dat.externalsampleapps.cameraaccess.conference.ConferenceContact
import com.meta.wearable.dat.externalsampleapps.cameraaccess.conference.ConferenceExtractionDisposition

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConferenceContactsSheet(
    contacts: List<ConferenceContact>,
    retryingContactIds: Set<String>,
    onDismiss: () -> Unit,
    onRefresh: () -> Unit,
    onRetry: (ConferenceContact) -> Unit,
) {
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    "Conference Contacts",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.SemiBold,
                )
                TextButton(onClick = onRefresh) {
                    Text("Refresh")
                }
            }

            if (contacts.isEmpty()) {
                Text(
                    "Accepted and review-band conference detections will appear here once they are captured.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(bottom = 24.dp),
                )
            } else {
                LazyColumn(
                    modifier = Modifier.fillMaxWidth(),
                    contentPadding = PaddingValues(bottom = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    items(contacts, key = { it.id }) { contact ->
                        ConferenceContactCard(
                            contact = contact,
                            isRetrying = retryingContactIds.contains(contact.id),
                            onRetry = onRetry,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ConferenceContactCard(
    contact: ConferenceContact,
    isRetrying: Boolean,
    onRetry: (ConferenceContact) -> Unit,
) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    contact.name,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                )
                if (contact.summaryText.isNotEmpty()) {
                    Text(
                        contact.summaryText,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(
                    contact.disposition.displayName,
                    style = MaterialTheme.typography.labelMedium,
                    color = if (contact.disposition == ConferenceExtractionDisposition.ACCEPTED) {
                        Color(0xFF4CAF50)
                    } else {
                        Color(0xFFFF9800)
                    },
                )
                Text(
                    contact.enrichmentStatus.displayName,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        Text(
            "${contact.sourceType.displayName} | ${(contact.confidence * 100).toInt()}% confidence",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        Text(
            "Last activity ${
                DateUtils.getRelativeTimeSpanString(
                    contact.lastActivityAtMs,
                    System.currentTimeMillis(),
                    DateUtils.MINUTE_IN_MILLIS,
                )
            }",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )

        val summary = contact.enrichment?.summaryText
        when {
            !summary.isNullOrBlank() -> {
                Text(summary, style = MaterialTheme.typography.bodyMedium)
            }

            !contact.enrichment?.rawResponse.isNullOrBlank() -> {
                Text(contact.enrichment?.rawResponse.orEmpty(), style = MaterialTheme.typography.bodyMedium)
            }

            !contact.enrichmentError.isNullOrBlank() -> {
                Text(
                    contact.enrichmentError.orEmpty(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }
        }

        if (!contact.enrichment?.talkingPoints.isNullOrEmpty()) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                contact.enrichment?.talkingPoints.orEmpty().forEach { point ->
                    Text(
                        "- $point",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        if (contact.hasConversationSnippet) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(
                    "Conversation",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    contact.conversationSnippet.orEmpty(),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }

        if (contact.canRetryEnrichment) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.End,
            ) {
                TextButton(
                    onClick = { onRetry(contact) },
                    enabled = !isRetrying,
                ) {
                    Text(if (isRetrying) "Retrying..." else "Retry Enrichment")
                }
            }
        }
    }
}
