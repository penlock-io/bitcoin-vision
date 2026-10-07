package com.bitcoinvision.example

import android.content.Intent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.ListItem
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import uniffi.bitcoin_vision_mobile.receiveAddresses

fun KeySource.description(): String = when (this) {
    KeySource.New -> "Made on this phone."
    KeySource.WrittenPhrase -> "Loaded from your written phrase."
    is KeySource.Strips ->
        "Loaded from share strips ${minOf(first, second)} and ${maxOf(first, second)}."
}

@Composable
fun ConnectWalletScreen(wallets: WalletsViewModel, id: String, onBack: () -> Unit) {
    val wallet = wallets.wallet(id)
    if (wallet == null) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    WalletPage("Connect to Sparrow", onBack, snackbar = snackbar) {
        Text(wallet.name, style = MaterialTheme.typography.titleLarge)
        Text(
            "Scan this in Sparrow to watch the wallet and build transactions for this phone to sign.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        StaticQr(wallet.descriptor, "Descriptor of ${wallet.name} as a QR code", "descriptor-qr", Modifier.fillMaxWidth())
        Card {
            SelectionContainer {
                Text(
                    wallet.descriptor,
                    style = MaterialTheme.typography.bodyMedium.copy(fontFamily = PlexMono),
                    modifier = Modifier.padding(16.dp).testTag("descriptor"),
                )
            }
        }
        Button(
            onClick = {
                val send = Intent(Intent.ACTION_SEND)
                    .setType("text/plain")
                    .putExtra(Intent.EXTRA_TEXT, wallet.descriptor)
                context.startActivity(Intent.createChooser(send, "Descriptor of ${wallet.name}"))
            },
            modifier = Modifier.fillMaxWidth().testTag("share-descriptor"),
        ) { Text("Share descriptor") }
        OutlinedButton(
            onClick = {
                clipboard.setText(AnnotatedString(wallet.descriptor))
                scope.launch { snackbar.showSnackbar("Descriptor copied") }
            },
            modifier = Modifier.fillMaxWidth().testTag("copy-descriptor"),
        ) { Text("Copy descriptor") }
    }
}

/** Addresses derived per step as the list nears its end. Numbered from 0, as Sparrow numbers them. */
private const val ADDRESS_STEP = 20u

/**
 * The receive addresses in order, more as the list is scrolled, from the
 * saved descriptor alone. The phone never sees the chain, so it cannot say
 * which are used: Sparrow can. Tapping one shows it as a QR code.
 */
@Composable
fun ReceiveScreen(wallets: WalletsViewModel, id: String, onBack: () -> Unit) {
    val wallet = wallets.wallet(id)
    if (wallet == null) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    val snackbar = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()
    val addresses = remember(wallet.descriptor) { mutableStateListOf<String>() }
    var failed by remember(wallet.descriptor) { mutableStateOf(false) }
    val more = {
        runCatching { receiveAddresses(wallet.descriptor, addresses.size.toUInt(), ADDRESS_STEP) }
            .onSuccess { addresses.addAll(it) }
            .onFailure { failed = true }
    }
    val list = rememberLazyListState()
    val nearEnd by remember {
        derivedStateOf {
            val last = list.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0
            last >= addresses.size - 5
        }
    }
    LaunchedEffect(nearEnd, addresses.size) { if (nearEnd && !failed) more() }
    var shown by remember(id) { mutableStateOf<Int?>(null) }
    WalletPage("Receive", onBack, snackbar = snackbar, scrolls = false) {
        Text(
            "Use a new address each time. Sparrow shows which ones have been used.",
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        if (failed && addresses.isEmpty()) {
            Text("This wallet's addresses could not be worked out.", color = MaterialTheme.colorScheme.error)
        }
        LazyColumn(Modifier.weight(1f).testTag("addresses"), state = list) {
            itemsIndexed(addresses) { i, address ->
                ListItem(
                    leadingContent = {
                        Text(
                            "$i",
                            style = MaterialTheme.typography.titleMedium,
                            modifier = Modifier.widthIn(min = 32.dp),
                        )
                    },
                    headlineContent = {
                        Text(address, style = MaterialTheme.typography.bodyMedium.copy(fontFamily = PlexMono))
                    },
                    modifier = Modifier.clickable { shown = i }.testTag("address-$i"),
                )
                HorizontalDivider()
            }
        }
    }
    val index = shown
    if (index != null) {
        val address = addresses[index]
        AlertDialog(
            onDismissRequest = { shown = null },
            title = { Text("Address $index") },
            text = {
                Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    StaticQr(address, "Address $index as a QR code", "address-qr", Modifier.fillMaxWidth())
                    SelectionContainer {
                        Text(
                            address,
                            style = MaterialTheme.typography.bodyMedium.copy(fontFamily = PlexMono),
                            modifier = Modifier.testTag("address"),
                        )
                    }
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedButton(
                            onClick = {
                                clipboard.setText(AnnotatedString(address))
                                scope.launch { snackbar.showSnackbar("Address copied") }
                            },
                            modifier = Modifier.weight(1f).testTag("copy-address"),
                        ) { Text("Copy") }
                        Button(
                            onClick = {
                                val send = Intent(Intent.ACTION_SEND)
                                    .setType("text/plain")
                                    .putExtra(Intent.EXTRA_TEXT, address)
                                context.startActivity(Intent.createChooser(send, "Address of ${wallet.name}"))
                            },
                            modifier = Modifier.weight(1f).testTag("share-address"),
                        ) { Text("Share") }
                    }
                }
            },
            confirmButton = { TextButton(onClick = { shown = null }) { Text("Close") } },
        )
    }
}

@Composable
fun KeyControlsScreen(
    wallets: WalletsViewModel,
    id: String,
    onBack: () -> Unit,
    onLoadKey: () -> Unit,
) {
    val wallet = wallets.wallet(id)
    if (wallet == null) {
        LaunchedEffect(Unit) { onBack() }
        return
    }
    val key = wallets.key(id)
    var confirmUnload by remember(id) { mutableStateOf(false) }
    // Revealing is local to this visit, never restored from saved state.
    DisposableEffect(id) {
        onDispose {
            if (wallets.revealed == id) wallets.revealed = null
        }
    }
    WalletPage("Secret words", onBack) {
        Text(wallet.name, style = MaterialTheme.typography.titleLarge)
        Text(
            if (key == null) "Scan your words to send" else "Ready to send",
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.testTag("key-status"),
        )
        if (key == null) {
            Button(onClick = onLoadKey, modifier = Modifier.fillMaxWidth().testTag("load-controls-key")) {
                Text("Scan your words")
            }
        } else {
            Text(key.source.description(), color = MaterialTheme.colorScheme.onSurfaceVariant)
            if (wallets.needsBackupWarning(id)) {
                Text("Not backed up on paper yet.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            val shown = wallets.revealed == id
            OutlinedButton(
                onClick = { wallets.revealed = if (shown) null else id },
                modifier = Modifier.fillMaxWidth().testTag("show-phrase"),
            ) { Text(if (shown) "Hide my 12 words" else "Show my 12 words") }
            if (shown) {
                Text("Keep the screen private.", style = MaterialTheme.typography.labelLarge)
                PhraseBody(key.words)
            }
            TextButton(
                onClick = { if (wallets.needsBackupWarning(id)) confirmUnload = true else wallets.unload(id) },
                modifier = Modifier.fillMaxWidth().testTag("unload"),
            ) { Text("Forget words now") }
        }
    }
    if (confirmUnload) {
        UnloadWarningDialog(
            onKeep = { confirmUnload = false },
            onUnload = { wallets.unload(id); confirmUnload = false },
        )
    }
}

@Composable
fun PhraseBody(words: List<String>) {
    val half = (words.size + 1) / 2
    Row(Modifier.padding(vertical = 4.dp)) {
        for (column in 0..1) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                for (i in column * half until minOf((column + 1) * half, words.size)) {
                    Text(
                        "${i + 1}. ${words[i]}",
                        style = MaterialTheme.typography.titleLarge.copy(fontFamily = PlexMono),
                        modifier = Modifier.testTag("word-${i + 1}"),
                    )
                }
            }
        }
    }
}
