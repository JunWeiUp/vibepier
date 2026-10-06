package io.github.junweiup.vibepier.remote.core.session

/** Business operations are UI projections of profile 2, never transport wire commands. */
internal object SessionProfilePolicy {
    val operations = setOf("list", "projects", "open", "close", "sync", "history", "parts", "message",
        "newOptions", "composerOptions", "approvalDetails", "contextUsage", "new", "send", "settings", "interrupt",
        "approve", "queueDelete", "queueSteer", "receipt", "receiptCheck", "newReceiptCheck",
        "settingsReceiptCheck", "interruptReceiptCheck", "queueReceiptCheck")

    // These still use the independent control service and its durable pending.* journal.
    fun independentMutation(op: String) = op in setOf("lockScreen", "unlockScreen", "codexUsageReset")
}
