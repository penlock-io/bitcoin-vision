package com.bitcoinvision.example

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AccountBalanceWallet
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp

/** The one place the app states its safety promise, so no other screen has to. */
const val SAFETY_LINE = "Keys are held in memory only. This phone never saves recovery words."

@Composable
fun WalletsScreen(wallets: WalletsViewModel, onAdd: () -> Unit, onOpen: (String) -> Unit) {
    var naming by remember { mutableStateOf(false) }
    if (naming) {
        NameNewWalletDialog(
            numbered = wallets.numberedName(),
            onDismiss = { naming = false },
            onChosen = { name -> naming = false; wallets.nameNext(name); onAdd() },
        )
    }
    WalletPage("Wallets", floatingAction = {
        if (wallets.wallets.isNotEmpty()) ExtendedFloatingActionButton(
            onClick = { naming = true },
            modifier = Modifier.testTag("add-wallet"),
            icon = { Icon(Icons.Default.Add, contentDescription = null) },
            text = { Text("Add wallet") },
        )
    }) {
        if (wallets.wallets.isEmpty()) {
            Text("Your wallet, on paper", style = MaterialTheme.typography.headlineSmall)
            Text("Create one, or scan one from paper.", modifier = Modifier.testTag("empty"))
            Button(onClick = { naming = true }, modifier = Modifier.testTag("add-wallet")) { Text("Add a wallet") }
        } else {
            Card {
                wallets.wallets.forEachIndexed { i, wallet ->
                    val loaded = wallets.key(wallet.id) != null
                    ListItem(
                        headlineContent = { Text(wallet.name) },
                        supportingContent = {
                            Text(
                                if (loaded) "Ready to send" else "Words not scanned",
                                style = MaterialTheme.typography.bodyMedium,
                                modifier = Modifier.testTag("wallet-$i-status"),
                            )
                        },
                        leadingContent = { Icon(Icons.Default.AccountBalanceWallet, contentDescription = null) },
                        modifier = Modifier.clickable { onOpen(wallet.id) }.testTag("wallet-$i"),
                    )
                }
            }
            Spacer(Modifier.height(80.dp))
        }
        Text(SAFETY_LINE, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Asked as adding begins, so the wallet is saved under its name. Skipping keeps the numbered one. */
@Composable
private fun NameNewWalletDialog(numbered: String, onDismiss: () -> Unit, onChosen: (String?) -> Unit) {
    var name by remember { mutableStateOf("") }
    val valid = normalizedWalletName(name) != null
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Name your wallet") },
        text = {
            OutlinedTextField(
                value = name,
                onValueChange = { name = it },
                singleLine = true,
                label = { Text("Wallet name") },
                placeholder = { Text(numbered) },
                supportingText = { Text("1–40 characters. You can change it later.") },
                modifier = Modifier.testTag("new-wallet-name-input"),
            )
        },
        confirmButton = {
            TextButton(
                onClick = { onChosen(name) },
                enabled = valid,
                modifier = Modifier.testTag("new-wallet-name-next"),
            ) { Text("Next") }
        },
        dismissButton = {
            TextButton(onClick = { onChosen(null) }, modifier = Modifier.testTag("new-wallet-name-skip")) {
                Text("Skip")
            }
        },
    )
}
