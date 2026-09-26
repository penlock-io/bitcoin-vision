package com.bitcoinvision.example

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Card
import androidx.compose.material3.Checkbox
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.unit.dp
import uniffi.bitcoin_vision_mobile.StripReading
import uniffi.bitcoin_vision_mobile.StripCellReview
import uniffi.bitcoin_vision_mobile.CombinedRowStatus
import uniffi.bitcoin_vision_mobile.CombinedStripReview

/** The camera and its result are separate in-page states; no Dialog window is needed. */
@Composable
fun StripScanScreen(
    viewModel: StripsViewModel,
    onRecovered: () -> Unit,
    onExit: () -> Unit,
) {
    // a photograph being read, or read and failed, is shown as the
    // photograph; a strip read, or a combination that failed, is the
    // result card
    when (val attempt = viewModel.attempts.current) {
        is Attempt.Preparing -> {
            CapturedPhotoScreen("Preparing your photo", null, null, onRetake = { viewModel.retake() },
                stripProgress = viewModel.progress, onProgressPresented = viewModel::progressPresented)
            return
        }
        is Attempt.Processing -> {
            CapturedPhotoScreen("Reading the strip", attempt.photo, null, onRetake = { viewModel.retake() },
                stripProgress = viewModel.progress, onProgressPresented = viewModel::progressPresented)
            return
        }
        is Attempt.Failed -> {
            CapturedPhotoScreen("No strip read", attempt.photo, attempt.message, onRetake = { viewModel.retake() }) {
                SavePhotoForDiagnosis { viewModel.savePhoto() }
                if (attempt.photo != null) SavePhotoForDiagnosis(canonical = true) { viewModel.saveCanonicalPhoto() }
            }
            return
        }
        else -> {}
    }
    val capture = viewModel.capture
    if (capture is Capture.Found || capture is Capture.Failed) {
        CaptureResult(viewModel, capture, onRecovered)
        return
    }
    BackHandler(onBack = onExit)
    val scanning = viewModel.scan as? StripScan.Scanning
    val heldNumber = scanning?.held?.let { viewModel.shareNumber(it) }
    CameraCapture(
        shutterEnabled = capture == null,
        onShutter = { viewModel.begin() },
        onJpeg = { token, photo -> viewModel.deliverPhoto(token, photo) },
        onExit = onExit,
        bar = {
            Column(Modifier.weight(1f)) {
                Text(
                    if (heldNumber == null) "1 of 2 · Scan first strip" else "2 of 2 · Scan second strip",
                    style = MaterialTheme.typography.titleMedium, color = Color.White,
                    modifier = Modifier.testTag("strip-scan-stage"),
                )
                if (heldNumber != null) Text(
                    "Share $heldNumber read", style = MaterialTheme.typography.bodyMedium, color = Color.White,
                )
            }
        },
    )
}

private fun readingSummary(strip: StripReading): String {
    val review = strip.review()
    val unread = review.rows.sumOf { row -> row.cells.count { it.unread && it.replacement == null } }
    val uncertain = review.rows.sumOf { row -> row.cells.count {
        !it.unread && it.replacement == null && (it.probability ?: 0f) < 0.75f
    } }
    return "${strip.rows()} rows read" +
        (if (unread > 0) ", $unread cells unread" else "") +
        (if (uncertain > 0) ", $uncertain low confidence" else "")
}

@Composable
private fun CaptureResult(viewModel: StripsViewModel, capture: Capture, onRecovered: () -> Unit) {
    val found = capture as? Capture.Found
    val raw = found?.let { viewModel.usable(it.strips) }
    val next = raw?.let(viewModel::currentStrip)
    val held = (viewModel.scan as? StripScan.Scanning)?.held
    val photo = viewModel.attempts.resolvedPhoto
    var cellEdit by remember(raw) { mutableStateOf<Pair<Int, StripCellReview>?>(null) }
    var rowEdit by remember(raw) { mutableStateOf<Int?>(null) }
    var acknowledged by remember(next) { mutableStateOf(false) }
    val pairState by produceState<Pair<CombinedStripReview?, Boolean>?>(null, held, next) {
        value = if (held != null && next != null) withContext(Dispatchers.Default) {
            Pair(viewModel.combinedReview(next), true)
        } else null
    }
    val pair = pairState?.first
    val flagged = pair?.rows?.any { it.status != CombinedRowStatus.EXACT } == true
    val retake = { viewModel.retake() }
    BackHandler(onBack = retake)
    TaskPage(
        title = if (next != null) "Review strip" else "Strip needs attention",
        onBack = retake,
        actions = {
            if (next != null) {
                Button(
                    onClick = { if (viewModel.use(next)) onRecovered() },
                    enabled = held == null || (pair != null && (!flagged || acknowledged)),
                    modifier = Modifier.fillMaxWidth().testTag("use"),
                ) { Text("Use share ${viewModel.shareNumber(next)}") }
                TextButton(onClick = retake, modifier = Modifier.fillMaxWidth().testTag("retake")) { Text("Retake") }
            } else {
                Button(onClick = retake, modifier = Modifier.fillMaxWidth().testTag("retake")) { Text("Retake") }
            }
        },
    ) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            if (next != null && photo != null) StripPhoto(photo, next.review())
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(
                        if (next != null) "Share ${viewModel.shareNumber(next)}" else if (found != null) "Not this strip" else "No strip read",
                        style = MaterialTheme.typography.headlineSmall,
                    )
                    Text(
                        when {
                            next != null -> readingSummary(next)
                            found != null -> viewModel.refusal(found.strips)
                            capture is Capture.Failed -> capture.message
                            else -> ""
                        },
                        modifier = Modifier.testTag("strip-read-result").semantics {
                            liveRegion = LiveRegionMode.Polite
                            stateDescription = if (next != null) "Ready to use" else "Retake needed"
                        },
                    )
                }
            }
            if (next != null) {
                Text("Check the share number and all twelve rows against your paper. A single share has no standalone checksum.")
                next.review().rows.forEachIndexed { rowIndex, row ->
                    Card(Modifier.fillMaxWidth().testTag("strip-row-${rowIndex + 1}")) {
                        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text("Row ${row.number}", style = MaterialTheme.typography.titleMedium)
                            Row(horizontalArrangement = Arrangement.spacedBy(3.dp)) {
                                row.cells.forEach { cell ->
                                    val shown = cell.replacement ?: cell.selected ?: "?"
                                    TextButton(onClick = { cellEdit = rowIndex to cell },
                                        modifier = Modifier.weight(1f)
                                            .background(if (cell.position < 2u) MaterialTheme.colorScheme.secondaryContainer
                                                else Color.Transparent)
                                            .testTag("strip-cell-${rowIndex + 1}-${cell.position + 1u}")) {
                                        Text(shown, color = when {
                                            cell.unread && cell.replacement == null -> MaterialTheme.colorScheme.error
                                            cell.replacement != null -> MaterialTheme.colorScheme.tertiary
                                            (cell.probability ?: 0f) < 0.75f -> MaterialTheme.colorScheme.error
                                            else -> MaterialTheme.colorScheme.onSurface
                                        })
                                    }
                                }
                            }
                            Text("First two: shares of checksum symbols · last four: word symbols",
                                style = MaterialTheme.typography.bodySmall)
                            Text(row.cells.joinToString(" · ") { cell ->
                                val p = cell.probability?.let { "${(it * 100).toInt()}%" } ?: "unread"
                                "${cell.position + 1u}: $p" + if (cell.replacement != null) " → ${cell.replacement}" else ""
                            }, style = MaterialTheme.typography.bodySmall)
                            TextButton(onClick = { rowEdit = rowIndex }, modifier = Modifier.testTag("edit-strip-row-${rowIndex + 1}")) {
                                Text("Edit full row")
                            }
                        }
                    }
                }
                if (held != null) {
                    Text("Combined check", style = MaterialTheme.typography.titleMedium)
                    viewModel.heldPhoto?.let { firstPhoto ->
                        Text("First share on its photo", style = MaterialTheme.typography.bodyMedium)
                        StripPhoto(firstPhoto, held.review())
                    }
                    if (pairState == null) Text("Checking combined rows…")
                    else if (pair == null) Text("The shares cannot be combined. Review unclear cells or retake.")
                    pair?.rows?.forEach { row ->
                        Text("Row ${row.number} · " + when (row.status) {
                            CombinedRowStatus.EXACT -> "word code matches combined reading"
                            CombinedRowStatus.CORRECTED -> "word code corrects symbol ${row.position!! + 1u}: ${row.observed} → ${row.expected}"
                            CombinedRowStatus.NEEDS_REVIEW -> "ambiguous or weak reading; check both strips"
                        }, color = if (row.status == CombinedRowStatus.NEEDS_REVIEW) MaterialTheme.colorScheme.error
                            else MaterialTheme.colorScheme.onSurface)
                    }
                    if (flagged) Row(Modifier.clickable { acknowledged = !acknowledged }) {
                        Checkbox(checked = acknowledged, onCheckedChange = null)
                        Text("I checked every corrected or uncertain row against both paper strips.")
                    }
                }
                viewModel.editError?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            }
            SavePhotoForDiagnosis { viewModel.savePhoto() }
            if (viewModel.attempts.resolvedPhoto != null) {
                SavePhotoForDiagnosis(canonical = true) { viewModel.saveCanonicalPhoto() }
            }
        }
    }
    cellEdit?.let { (row, cell) ->
        AlertDialog(
            onDismissRequest = { cellEdit = null },
            title = { Text("Row ${row + 1}, cell ${cell.position + 1u}") },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    Text("Model: ${cell.selected ?: "unread"} · ${cell.probability?.let { "${(it * 100).toInt()}%" } ?: "no confidence"}")
                    "=#ABCDEFGHIJKLMNOPQRSTUVWXYZ-".chunked(6).forEach { line ->
                        Row {
                            line.forEach { symbol ->
                                TextButton(onClick = {
                                    viewModel.correctCell(raw!!, row, cell.position.toInt(), symbol.toString())
                                    cellEdit = null
                                }) { Text(symbol.toString()) }
                            }
                        }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { cellEdit = null }) { Text("Close") } },
            dismissButton = { if (cell.replacement != null) TextButton(onClick = {
                viewModel.resetCell(raw!!, row, cell.position.toInt()); cellEdit = null
            }) { Text("Use model read") } },
        )
    }
    rowEdit?.let { row ->
        var text by remember(row) { mutableStateOf(next!!.review().rows[row].cells.joinToString("") { it.replacement ?: it.selected ?: "?" }) }
        AlertDialog(onDismissRequest = { rowEdit = null },
            title = { Text("Edit row ${row + 1}") },
            text = { OutlinedTextField(value = text, onValueChange = { text = it.uppercase().take(6) },
                label = { Text("Six worksheet symbols") }, singleLine = true) },
            confirmButton = { TextButton(onClick = { viewModel.correctRow(raw!!, row, text); rowEdit = null }) { Text("Apply") } },
            dismissButton = { TextButton(onClick = { rowEdit = null }) { Text("Cancel") } })
    }
}
