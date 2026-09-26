package com.bitcoinvision.example

import android.graphics.Bitmap
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import uniffi.bitcoin_vision_mobile.StripReview

/** Canonical photo coordinates from the native strip and production cell windows. */
@Composable
internal fun StripPhoto(
    photo: ResolvedPhoto,
    review: StripReview?,
    progress: StripProgressState? = null,
    bitmap: Bitmap? = rememberPhotoBitmap(photo).value,
    onPresented: () -> Unit = {},
) {
    val image = bitmap ?: return
    val colours = MaterialTheme.colorScheme
    val limit = 420.dp / LocalDensity.current.fontScale.coerceAtLeast(1f)
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val height = minOf(limit, maxWidth * photo.height / photo.width)
        Canvas(Modifier.fillMaxWidth().height(height).background(colours.surfaceContainer)
            .testTag("captured-photo").semantics { contentDescription = "Photographed strip and cell windows" }) {
            val fit = fitPhoto(PhotoFrame(photo.width, photo.height), size.width, size.height) ?: return@Canvas
            drawImage(image.asImageBitmap(), dstOffset = IntOffset(fit.left, fit.top),
                dstSize = IntSize(fit.width, fit.height))
            fun outline(corners: List<Float>, colour: androidx.compose.ui.graphics.Color, width: Float) {
                if (corners.size != 8 || corners.any { !it.isFinite() }) return
                val path = Path().apply {
                    for (i in 0..3) {
                        val x = fit.x(corners[2 * i]); val y = fit.y(corners[2 * i + 1])
                        if (i == 0) moveTo(x, y) else lineTo(x, y)
                    }
                    close()
                }
                drawPath(path, colours.surface.copy(alpha = 0.85f), style = Stroke(width + 2.dp.toPx()))
                drawPath(path, colour, style = Stroke(width))
            }
            if (review != null) {
                outline(review.corners, colours.primary, 2.5.dp.toPx())
                review.rows.forEach { row -> row.cells.forEach { cell ->
                    outline(cell.corners,
                        if (cell.unread && cell.replacement == null) colours.error
                        else if (cell.replacement != null) colours.tertiary
                        else if ((cell.probability ?: 0f) < 0.75f) colours.error
                        else colours.primary.copy(alpha = 0.75f), 1.dp.toPx())
                } }
            } else if (progress?.frame == PhotoFrame(photo.width, photo.height)) {
                progress.regions.values.forEach { region ->
                    outline(region.corners, if (region.read) colours.primary else colours.onSurfaceVariant,
                        if (region.read) 2.dp.toPx() else 1.5.dp.toPx())
                }
            }
            onPresented()
        }
    }
}

@Composable
internal fun StripProgressPhoto(photo: ResolvedPhoto, progress: StripProgressState, onPresented: () -> Unit) =
    StripPhoto(photo, null, progress, onPresented = onPresented)
