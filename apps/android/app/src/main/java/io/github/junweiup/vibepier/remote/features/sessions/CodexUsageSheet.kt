package io.github.junweiup.vibepier.remote.features.sessions

import android.app.AlertDialog
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Typeface
import android.view.View
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.ScrollView
import io.github.junweiup.vibepier.remote.R
import io.github.junweiup.vibepier.remote.core.session.SessionResponseInbox
import io.github.junweiup.vibepier.remote.core.ui.Ui
import io.github.junweiup.vibepier.remote.core.ui.showProtected
import io.github.junweiup.vibepier.remote.features.remote.Palette
import org.json.JSONObject
import java.text.DateFormat
import java.util.Date
import java.util.UUID

/** Fresh account usage plus explicit, single-submission redemption of a gifted reset. */
@android.annotation.SuppressLint("ViewConstructor")
class CodexUsageSheet(context: Context,
    private val request: (String, JSONObject, (JSONObject) -> Unit) -> Unit,
    private val pending: () -> List<JSONObject>,
    private val clearReceipt: (String) -> Unit
) : ScrollView(context) {
    private val content = LinearLayout(context).apply { orientation = LinearLayout.VERTICAL }
    private var snapshot: JSONObject? = null
    private var busy = false
    private var generation = 0
    private var disposed = false
    private var confirmation: AlertDialog? = null
    private var message = ""
    init { isFillViewport = true; addView(content); render() }
    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()
    private fun text(value: String, size: Float = Ui.BODY, muted: Boolean = false) = Ui.label(context, value, size, if (muted) Palette.muted else Palette.text)
    private fun add(view: View, top: Int = 10) = content.addView(view, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(top) })
    private fun button(title: String, enabled: Boolean = true, action: () -> Unit) = Ui.button(context, title, action = action).apply { isEnabled = enabled; alpha = if (enabled) 1f else .45f }
    private fun params() = JSONObject().put("provider", "codex")
    private fun unresolved() = pending().filter { it.optString("op") == "codexUsageReset" }
    override fun onDetachedFromWindow() { disposed = true; generation++; confirmation?.dismiss(); confirmation = null; super.onDetachedFromWindow() }

    fun refresh(resultMessage: String = "") {
        if (busy || disposed) return
        busy = true; snapshot = null; message = resultMessage.ifBlank { context.getString(R.string.codex_usage_loading) }; render()
        val token = ++generation
        request("codexUsage", params()) { result ->
            if (disposed || token != generation) return@request
            busy = false
            if (result.optBoolean("ok")) { snapshot = result; message = resultMessage }
            else message = listOf(resultMessage, result.optString("error", context.getString(R.string.codex_usage_unavailable))).filter { it.isNotBlank() }.joinToString("\n")
            render()
        }
    }

    private fun render() {
        content.removeAllViews()
        add(text(context.getString(R.string.codex_usage_account_scope), Ui.CAPTION, true), 0)
        add(button(context.getString(if (busy) R.string.codex_usage_loading else R.string.codex_usage_refresh), !busy) { refresh() })
        if (message.isNotEmpty()) add(text(message, Ui.CAPTION, true))
        val waiting = unresolved()
        if (waiting.isNotEmpty()) {
            add(text(context.getString(R.string.codex_usage_pending), Ui.CAPTION, true))
            add(button(context.getString(R.string.codex_usage_check_receipt), !busy) { checkReceipt(waiting.first()) })
        }
        val data = snapshot ?: return
        val windows = data.optJSONArray("windows")
        if (windows == null || windows.length() == 0) add(text(context.getString(R.string.codex_usage_windows_unknown), Ui.CAPTION, true))
        else for (i in 0 until windows.length()) {
            val window = windows.optJSONObject(i) ?: continue
            val minutes = window.optLong("windowDurationMins", -1)
            val period = when (minutes) { 300L -> context.getString(R.string.codex_usage_five_hours); 10080L -> context.getString(R.string.codex_usage_weekly); else -> if (minutes > 0) context.getString(R.string.codex_usage_window_minutes, minutes) else context.getString(R.string.codex_usage_window_unknown) }
            val name = if (window.optString("limitId") == "codex") "Codex" else window.optString("name")
            val remaining = window.optInt("remainingPercent", -1)
            val card = LinearLayout(context).apply {
                orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(14), dp(16), dp(14)); background = Ui.roundRect(context, Palette.surface1, 14)
                addView(text("$name · $period", Ui.CAPTION, true))
                addView(text(if (remaining in 0..100) context.getString(R.string.codex_usage_remaining, remaining) else context.getString(R.string.codex_usage_windows_unknown), 25f).apply { typeface = Typeface.DEFAULT_BOLD })
                if (remaining in 0..100) addView(ProgressBar(context, null, android.R.attr.progressBarStyleHorizontal).apply {
                    max = 100; progress = remaining; progressTintList = ColorStateList.valueOf(Palette.accent)
                    importantForAccessibility = IMPORTANT_FOR_ACCESSIBILITY_NO
                }, LinearLayout.LayoutParams(-1, dp(6)).apply { topMargin = dp(8); bottomMargin = dp(8) })
                addView(text(context.getString(R.string.codex_usage_resets_at, time(window.optLong("resetsAt", -1))), Ui.CAPTION, true))
            }
            add(card)
        }
        val count = if (data.isNull("availableCount")) null else data.optInt("availableCount", -1).takeIf { it >= 0 }
        add(text(if (count == null) context.getString(R.string.codex_usage_cards_unknown) else context.getString(R.string.codex_usage_cards_count, count)).apply { typeface = Typeface.DEFAULT_BOLD }, 18)
        if (count == 0) add(text(context.getString(R.string.codex_usage_no_cards), Ui.CAPTION, true))
        val eligible = data.optBoolean("resetEligible")
        if (!eligible && count != null && count > 0) add(text(context.getString(R.string.codex_usage_not_eligible, 10), Ui.CAPTION, true))
        val cards = data.optJSONArray("resetCards")
        if (cards != null) for (i in 0 until cards.length()) {
            val card = cards.optJSONObject(i) ?: continue
            resetCard(data, card.optString("id"), card.optString("title").ifBlank { context.getString(R.string.codex_usage_full_reset) }, card.optLong("expiresAt", -1), eligible && card.optBoolean("available") && waiting.isEmpty() && !busy)
        }
        if (count != null && count > 0 && !data.optBoolean("cardDetailsKnown")) {
            add(text(context.getString(R.string.codex_usage_card_details_missing), Ui.CAPTION, true))
        }
        add(text(context.getString(R.string.codex_usage_updated_at, time(data.optLong("fetchedAt", -1))), Ui.CAPTION, true), 16)
    }

    private fun resetCard(data: JSONObject, id: String, title: String, expiry: Long, enabled: Boolean) {
        val card = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL; setPadding(dp(16), dp(14), dp(16), dp(14)); background = Ui.roundRect(context, Palette.surface1, 14)
            addView(text(title).apply { typeface = Typeface.DEFAULT_BOLD })
            addView(text(if (expiry > 0) context.getString(R.string.codex_usage_expires_at, time(expiry)) else context.getString(R.string.codex_usage_expiry_none), Ui.CAPTION, true))
            addView(button(context.getString(R.string.codex_usage_use_card), enabled) { confirm(data.optString("accountId"), id, title) }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = dp(10) })
        }
        add(card)
    }
    private fun confirm(account: String, credit: String, title: String) {
        if (busy || disposed || unresolved().isNotEmpty() || confirmation?.isShowing == true || snapshot?.optBoolean("resetEligible") != true) return
        confirmation = AlertDialog.Builder(context, R.style.Theme_VibePier_Dialog)
            .setTitle(R.string.codex_usage_confirm_title).setMessage(context.getString(R.string.codex_usage_confirm_body, title))
            .setNegativeButton(R.string.codex_usage_cancel, null)
            .setPositiveButton(R.string.codex_usage_confirm_use) { _, _ -> redeem(account, credit) }.showProtected()
    }
    private fun redeem(account: String, credit: String) {
        if (busy || disposed || unresolved().isNotEmpty() || account != snapshot?.optString("accountId")) return
        busy = true; message = context.getString(R.string.codex_usage_redeeming); render()
        val token = ++generation
        val intent = params().put("id", UUID.randomUUID().toString()).put("accountId", account).put("creditId", credit).put("confirm", true)
        request("codexUsageReset", intent) { result ->
            if (disposed || token != generation) return@request
            busy = false
            if (result.optBoolean("unknown")) { snapshot = null; message = context.getString(R.string.codex_usage_pending); render() }
            else refresh(outcome(result))
        }
    }
    private fun checkReceipt(original: JSONObject) {
        if (busy || disposed) return
        busy = true; render(); val token = ++generation
        request("receipt", params().put("operation", original.optString("id"))) { result ->
            if (disposed || token != generation) return@request
            busy = false
            val receipt = result.optJSONObject("receipt")
            when {
                result.optBoolean("ok") && result.optString("state") == "complete" && receipt != null && SessionResponseInbox.confirms(receipt, original) -> { clearReceipt(original.optString("id")); refresh(outcome(receipt)) }
                result.optBoolean("ok") && result.optString("state") == "notFound" -> { clearReceipt(original.optString("id")); refresh(context.getString(R.string.codex_usage_not_submitted)) }
                else -> { message = context.getString(R.string.codex_usage_pending); render() }
            }
        }
    }
    private fun outcome(value: JSONObject): String {
        if (!value.optBoolean("ok")) return value.optString("error", context.getString(R.string.codex_usage_unavailable))
        return context.getString(when (value.optString("outcome")) {
            "reset", "alreadyRedeemed" -> R.string.codex_usage_reset_done
            "nothingToReset" -> R.string.codex_usage_nothing_to_reset
            "noCredit" -> R.string.codex_usage_no_cards
            else -> R.string.codex_usage_pending
        })
    }
    private fun time(seconds: Long): String = if (seconds in 1..253402300799L) DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT).format(Date(seconds * 1000)) else context.getString(R.string.codex_usage_time_unknown)
}
