package com.bitcoinvision.example

import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag

/** The destination is a task label, never the pending request or key itself. */
@Composable
fun LoadKeyScreen(
    wallets: WalletsViewModel,
    id: String,
    task: String,
    onBack: () -> Unit,
    onScanPhrase: () -> Unit,
    onScanStrips: () -> Unit,
) {
    val wallet = wallets.wallet(id)
    if (wallet == null) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    WalletPage("Scan your words", onBack, titleTag = "load-title") {
        Text(wallet.name, style = MaterialTheme.typography.titleLarge)
        Text("Scan your words to send", modifier = Modifier.testTag("key-status"))
        Text(
            when (task) {
                "sign" -> "After scanning, you go back to the transaction and tap Sign."
                "backup" -> "After scanning, you write a new set of three strips."
                else -> "From your 12 written words or any two strips."
            },
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.testTag("load-purpose"),
        )
        wallets.notice?.takeIf { it.walletId == id }?.let {
            Text(it.text, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("notice"))
        }
        Button(onClick = onScanPhrase, modifier = Modifier.fillMaxWidth().testTag("scan-phrase")) {
            Text("Scan a written phrase")
        }
        OutlinedButton(onClick = onScanStrips, modifier = Modifier.fillMaxWidth().testTag("scan-strips")) {
            Text("Scan two share strips")
        }
    }
}
