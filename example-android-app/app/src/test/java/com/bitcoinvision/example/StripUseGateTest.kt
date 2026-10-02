package com.bitcoinvision.example

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.bitcoin_vision_mobile.CombinedRowReview
import uniffi.bitcoin_vision_mobile.CombinedRowStatus
import uniffi.bitcoin_vision_mobile.CombinedStripReview

class StripUseGateTest {
    private fun pair(vararg statuses: CombinedRowStatus) = CombinedStripReview(
        (0 until 12).map { index ->
            CombinedRowReview((index + 1).toUInt(),
                statuses.getOrElse(index) { CombinedRowStatus.EXACT }, null, null, null)
        },
    )

    @Test fun first_share_can_be_held_without_a_pair_check() {
        assertTrue(shareUseAllowed(false, null, false))
    }

    @Test fun second_share_requires_a_fresh_valid_pair_check() {
        assertFalse(shareUseAllowed(true, null, false))
        assertFalse(shareUseAllowed(true, null, true))
        assertFalse(shareUseAllowed(true, CombinedStripReview(emptyList()), true))
        assertTrue(shareUseAllowed(true, pair(CombinedRowStatus.EXACT), false))
    }

    @Test fun correction_or_uncertainty_requires_paper_check_before_use() {
        for (status in listOf(CombinedRowStatus.CORRECTED, CombinedRowStatus.NEEDS_REVIEW)) {
            val changed = pair(CombinedRowStatus.EXACT, status)
            assertFalse(shareUseAllowed(true, changed, false))
            assertTrue(shareUseAllowed(true, changed, true))
        }
        // Retaking or editing invalidates the old check; acknowledgement alone
        // cannot authorize a result that has not been recomputed.
        assertFalse(shareUseAllowed(true, null, true))
    }

    @Test fun edit_then_retake_never_reuses_the_previous_pair_or_paper_check() {
        val exact = pair(CombinedRowStatus.EXACT)
        val edited = pair(CombinedRowStatus.CORRECTED)
        assertTrue(shareUseAllowed(false, null, false)) // hold the first share
        assertTrue(shareUseAllowed(true, exact, false))
        assertFalse(shareUseAllowed(true, edited, false)) // an edit needs paper review
        assertTrue(shareUseAllowed(true, edited, true))
        assertFalse(shareUseAllowed(true, null, true)) // retake discards that pair
        assertFalse(shareUseAllowed(true, edited, false)) // the new capture starts unchecked
    }
}
