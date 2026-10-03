package io.github.junweiup.vibepier.remote

import android.app.AlertDialog
import android.app.Instrumentation
import android.content.Intent
import android.os.SystemClock
import android.view.View
import android.view.ViewGroup
import io.github.junweiup.vibepier.remote.features.sessions.CodexUsageSheet
import io.github.junweiup.vibepier.remote.features.sessions.ConversationPanel
import org.json.JSONArray
import org.json.JSONObject

/** Native layout and confirmation with synthetic account replies; never redeems a real reset. */
object CodexUsageProbe {
    fun run(test: Instrumentation): String {
        fun views(root: View): List<View> = listOf(root) + if (root is ViewGroup) (0 until root.childCount).flatMap { views(root.getChildAt(it)) } else emptyList()
        fun main(block: () -> Unit) {
            var failure: Throwable? = null
            test.runOnMainSync { try { block() } catch (error: Throwable) { failure = error } }
            failure?.let { throw it }
        }
        val activity = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "approval"))
        var resets = 0
        var reads = 0
        var unknown = false
        val pending = mutableListOf<JSONObject>()
        var resetReply: ((JSONObject) -> Unit)? = null
        lateinit var sheet: CodexUsageSheet
        try {
            main {
                sheet = CodexUsageSheet(activity, { op, fields, reply ->
                    check(fields.optString("provider") == "codex")
                    when (op) {
                        "codexUsage" -> {
                            reads++
                            reply(JSONObject().put("ok", true).put("accountId", "demo-account").put("resetEligible", true).put("availableCount", 3).put("cardDetailsKnown", true).put("fetchedAt", System.currentTimeMillis() / 1000)
                                .put("windows", JSONArray().put(JSONObject().put("limitId", "codex").put("windowDurationMins", 10080).put("remainingPercent", 7).put("resetsAt", System.currentTimeMillis() / 1000 + 3600)))
                                .put("resetCards", JSONArray().put(JSONObject().put("id", "demo-gift").put("title", activity.getString(R.string.codex_usage_full_reset)).put("available", true).put("expiresAt", System.currentTimeMillis() / 1000 + 7200))))
                        }
                        "codexUsageReset" -> {
                            resets++; check(fields.optBoolean("confirm")); check(fields.optString("accountId") == "demo-account"); check(fields.optString("creditId") == "demo-gift")
                            check(java.util.UUID.fromString(fields.getString("id")) != null)
                            pending.add(JSONObject(fields.toString()).put("op", op)); resetReply = reply
                        }
                        "receipt" -> reply(JSONObject().put("ok", true).put("state", if (unknown) "unknown" else "notFound"))
                        else -> error("Unexpected operation: $op")
                    }
                }, { pending.toList() }, { id -> pending.removeAll { it.optString("id") == id } })
                activity.setContentView(sheet); sheet.refresh()
            }
            test.waitForIdleSync(); SystemClock.sleep(150)
            main {
                val labels = views(sheet).mapNotNull { it.contentDescription?.toString() }
                check(activity.getString(R.string.codex_usage_remaining, 7) in labels)
                check(activity.getString(R.string.codex_usage_cards_count, 3) in labels)
                check(labels.any { it.contains(activity.getString(R.string.codex_usage_weekly)) })
                val use = views(sheet).single { it.contentDescription == activity.getString(R.string.codex_usage_use_card) }
                use.performClick()
                val dialog = sheet.javaClass.getDeclaredField("confirmation").apply { isAccessible = true }.get(sheet) as AlertDialog
                dialog.getButton(AlertDialog.BUTTON_NEGATIVE).performClick()
            }
            test.waitForIdleSync()
            main {
                check(resets == 0)
                val use = views(sheet).single { it.contentDescription == activity.getString(R.string.codex_usage_use_card) }
                use.performClick()
                val confirm = sheet.javaClass.getDeclaredField("confirmation").apply { isAccessible = true }.get(sheet) as AlertDialog
                confirm.getButton(AlertDialog.BUTTON_POSITIVE).performClick()
            }
            test.waitForIdleSync()
            main {
                val use = views(sheet).single { it.contentDescription == activity.getString(R.string.codex_usage_use_card) }
                check(resets == 1); use.performClick(); check(resets == 1)
                unknown = true
                resetReply!!(JSONObject().put("ok", false).put("unknown", true))
                check(views(sheet).any { it.contentDescription == activity.getString(R.string.codex_usage_pending) })
                sheet.refresh()
                check(views(sheet).filter { it.contentDescription == activity.getString(R.string.codex_usage_use_card) }.all { !it.isEnabled })
                views(sheet).single { it.contentDescription == activity.getString(R.string.codex_usage_check_receipt) }.performClick()
                check(resets == 1 && pending.size == 1)
                unknown = false
                views(sheet).single { it.contentDescription == activity.getString(R.string.codex_usage_check_receipt) }.performClick()
                check(pending.isEmpty()); check(resets == 1)
            }
            check(reads >= 3)
            main { activity.finish() }; test.waitForIdleSync()
            val preview = test.startActivitySync(Intent(test.targetContext, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("codexFixture", "approval")) as MainActivity
            try {
                test.waitForIdleSync()
                lateinit var panel: ConversationPanel
                main {
                    panel = preview.sessionNavigation.panel as ConversationPanel
                    panel.javaClass.getDeclaredMethod("showDrawerMenu").apply { isAccessible = true }.invoke(panel)
                    @Suppress("UNCHECKED_CAST") val dialogs = panel.javaClass.getDeclaredField("auxiliaryDialogs").apply { isAccessible = true }.get(panel) as Set<AlertDialog>
                    val menu = dialogs.last { it.isShowing }
                    views(menu.window!!.decorView).single { it.contentDescription == preview.getString(R.string.codex_usage_title) && it.isClickable }.performClick()
                }
                SystemClock.sleep(250); test.waitForIdleSync()
                main {
                    @Suppress("UNCHECKED_CAST") val dialogs = panel.javaClass.getDeclaredField("auxiliaryDialogs").apply { isAccessible = true }.get(panel) as Set<AlertDialog>
                    val dialog = dialogs.last { it.isShowing }
                    val children = views(dialog.window!!.decorView)
                    check(children.any { it is CodexUsageSheet })
                    check(children.any { it.contentDescription == preview.getString(R.string.codex_usage_remaining, 7) })
                    val close = children.single { it.contentDescription == preview.getString(R.string.codex_usage_close) && it.isClickable }
                    val rect = android.graphics.Rect(); check(close.getGlobalVisibleRect(rect) && rect.height() == close.height)
                }
                test.uiAutomation.takeScreenshot()?.let { bitmap ->
                    try { java.io.File(preview.externalCacheDir, "codex-usage.png").outputStream().use { bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) } } finally { bitmap.recycle() }
                }
            } finally { main { preview.finish() } }
            return "PASS: remaining usage/reset time/cards, cancellation, explicit single redemption, unknown-result protection and read-only receipt checks; synthetic account only\n"
        } finally { main { activity.finish() } }
    }
}
