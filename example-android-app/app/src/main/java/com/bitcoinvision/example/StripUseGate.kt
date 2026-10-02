package com.bitcoinvision.example

import uniffi.bitcoin_vision_mobile.CombinedRowStatus
import uniffi.bitcoin_vision_mobile.CombinedStripReview

/** The second share needs a valid pair check and explicit paper confirmation for any non-exact row. */
internal fun shareUseAllowed(
    firstShareHeld: Boolean,
    pair: CombinedStripReview?,
    paperChecked: Boolean,
): Boolean = !firstShareHeld ||
    (pair != null && pair.rows.size == 12 &&
        (pair.rows.all { it.status == CombinedRowStatus.EXACT } || paperChecked))
