package io.github.junweiup.vibepier.remote

import io.github.junweiup.vibepier.remote.features.remote.BindingSync

import android.app.Instrumentation
import android.app.Activity
import android.os.Bundle
import android.content.Context
import org.json.JSONObject

/** Runs against Android SharedPreferences/JSON; uses only an isolated test preference file. */
class BindingSyncInstrumentation : Instrumentation() {
    private var probeName = "binding-sync"
    private var uploadPort = 0
    private var responseOnly = false
    private var privateStorageOnly = false
    private var controlsLocalizationOnly = false
    private var screenControlsOnly = false
    private var newSessionReceiptOnly = false
    private var relayStoreOnly = false
    private var enrollmentOnly = false
    private var backgroundOnly = false
    private var protocolOnly = false
    private var relayFramingOnly = false
    private var apkOnly = false
    private var composerOnly = false
    private var audioOnly = false
    private var controlsOnly = false
    private var dockOnly = false
    private var codexOnly = false
    private var codexPanelOnly = false
    private var providersOnly = false
    private var toolGroupsOnly = false
    private var markdownOnly = false
    private var appUsageOnly = false
    private var imagesOnly = false
    override fun onCreate(arguments: Bundle?) {
        super.onCreate(arguments)
        probeName = arguments?.getString("test") ?: "binding-sync"
        uploadPort = arguments?.getString("port")?.toIntOrNull() ?: 0
        responseOnly = arguments?.getString("test") == "session-response"
        privateStorageOnly = arguments?.getString("test") == "private-storage"
        controlsLocalizationOnly = arguments?.getString("test") == "controls-localization"
        screenControlsOnly = arguments?.getString("test") == "screen-controls"
        newSessionReceiptOnly = arguments?.getString("test") == "new-session-receipts"
        relayStoreOnly = arguments?.getString("test") == "relay-store"
        enrollmentOnly = arguments?.getString("test") == "enrollment"
        backgroundOnly = arguments?.getString("test") == "background-connection"
        protocolOnly = arguments?.getString("test") == "protocol-negotiation"
        relayFramingOnly = arguments?.getString("test") == "relay-framing"
        apkOnly = arguments?.getString("test") == "apk"
        composerOnly = arguments?.getString("test") == "composer"
        audioOnly = arguments?.getString("test") == "microphone"
        controlsOnly = arguments?.getString("test") == "controls"
        dockOnly = arguments?.getString("test") == "dock"
        codexPanelOnly = arguments?.getString("test") == "codex-panel"
        codexOnly = arguments?.getString("test") == "codex"
        providersOnly = arguments?.getString("test") == "providers"
        toolGroupsOnly = arguments?.getString("test") == "tool-groups"
        markdownOnly = arguments?.getString("test") == "markdown"
        appUsageOnly = arguments?.getString("test") == "app-usage"
        imagesOnly = arguments?.getString("test") == "conversation-images"
        start()
    }
    override fun onStart() {
        val result = Bundle()
        result.putString("probe", probeName)
        result.putString("locale", targetContext.resources.configuration.locales.toLanguageTags())
        try {
            check(probeName in setOf("binding-sync", "session-response", "private-storage", "controls-localization",
                "screen-controls", "new-session-receipts", "new-session-composer", "relay-store", "enrollment", "background-connection",
                "protocol-negotiation", "relay-framing", "apk", "composer", "microphone", "controls", "dock",
                "codex", "codex-panel", "providers", "provider-access", "tool-groups", "markdown", "app-usage", "conversation-images", "codex-usage", "application-picker", "brand-icons", "codec-compatibility", "readme-previews", "session-blocker", "voice-layout", "conversation-scroll", "binary-files", "binary-media", "attachment-upload", "attachment-network-upload", "task-notifications", "app-versions", "html-preview", "video-preview", "audit-runtime", "audit-conversation", "plan-mode", "agent-open", "image-zoom")) {
                "Unknown instrumentation probe"
            }
            if (probeName == "plan-mode") { result.putString("stream", PlanModeProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "agent-open") { result.putString("stream", AgentOpenProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "image-zoom") { result.putString("stream", ImageZoomProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "codec-compatibility") { result.putString("stream", CodecCompatibilityProbe.run()); finish(Activity.RESULT_OK, result); return }
            if (probeName == "video-preview") { result.putString("stream", VideoPreviewProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "html-preview") { result.putString("stream", HtmlPreviewProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "app-versions") { result.putString("stream", AppVersionProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "task-notifications") { result.putString("stream", TaskNotificationProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "session-blocker") { result.putString("stream", SessionBlockerProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "attachment-network-upload") { result.putString("stream", AttachmentNetworkUploadProbe.run(this, uploadPort)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "attachment-upload") { result.putString("stream", AttachmentUploadProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "binary-media") { result.putString("stream", BinaryMediaProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "binary-files") { result.putString("stream", BinaryFileProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "conversation-scroll") { result.putString("stream", ConversationScrollProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "voice-layout") { result.putString("stream", VoiceLayoutProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "readme-previews") { result.putString("stream", ReadmePreviewProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "audit-runtime") { result.putString("stream", AuditRuntimeProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "audit-conversation") { result.putString("stream", ConversationAuditProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "brand-icons") { result.putString("stream", BrandAssetsProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "application-picker") { result.putString("stream", ApplicationPickerProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "codex-usage") { result.putString("stream", CodexUsageProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "new-session-composer") { result.putString("stream", NewSessionComposerProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (responseOnly) { result.putString("stream", SessionResponseProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (controlsLocalizationOnly) { result.putString("stream", ControlsLocalizationProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (privateStorageOnly) { result.putString("stream", PrivatePreferencesProbe.run(targetContext)); finish(Activity.RESULT_OK, result); return }
            if (newSessionReceiptOnly) { result.putString("stream", NewSessionReceiptProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (screenControlsOnly) { result.putString("stream", ScreenControlsProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (relayStoreOnly) { result.putString("stream", RelaySettingsStoreProbe.run(targetContext)); finish(Activity.RESULT_OK, result); return }
            if (enrollmentOnly) { result.putString("stream", EnrollmentProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (backgroundOnly) { result.putString("stream", BackgroundConnectionProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (protocolOnly) { result.putString("stream", ProtocolNegotiationProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (relayFramingOnly) { result.putString("stream", RelayFramingProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (imagesOnly) { result.putString("stream", ConversationImagesProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (apkOnly) { result.putString("stream", ApkReceiverProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (probeName == "provider-access") { result.putString("stream", ProviderAccessProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (providersOnly) { result.putString("stream", SessionProviderProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (toolGroupsOnly) { result.putString("stream", ToolGroupingProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (markdownOnly) { result.putString("stream", MarkdownFileViewerProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (appUsageOnly) { result.putString("stream", AppUsageProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (composerOnly) { result.putString("stream", CodexComposerProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (codexPanelOnly) { result.putString("stream", ConversationPanelProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (codexOnly) { result.putString("stream", SessionClientProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (controlsOnly) { result.putString("stream", ControlViewProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (dockOnly) { result.putString("stream", ApplicationDockProbe.run(this)); finish(Activity.RESULT_OK, result); return }
            if (audioOnly) { result.putString("stream", PhoneMicrophoneProbe.run(targetContext.resources)); finish(Activity.RESULT_OK, result); return }
            val prefs = targetContext.getSharedPreferences("binding-sync-test", Context.MODE_PRIVATE)
            fun clear() { prefs.edit().clear().commit() }
            val sent = mutableListOf<JSONObject>()
            val notices = mutableListOf<String>()
            fun sync() = BindingSync(prefs, { sent.add(JSONObject(it.toString())) }, {}, {}, notices::add, "fixture key conflict")
            fun entry(value: String?, version: String, generation: Int) = JSONObject()
                .put("value", value ?: JSONObject.NULL).put("version", version).put("generation", generation).put("name", "Editor")
            fun snapshot(entries: JSONObject = JSONObject()) = JSONObject().put("server", "mac").put("entries", entries)
            fun ack(op: JSONObject, entry: JSONObject, accepted: Boolean = true) = JSONObject()
                .put("server", "mac").put("key", op.getString("key")).put("operation", op.getString("operation"))
                .put("accepted", accepted).put("entry", entry)
            clear()
            prefs.edit().putString("keys.talk", "fn").putString("app.org.editor.keys.confirm", "cmd+return").commit()
            var s = sync()
            s.snapshot(snapshot())
            check(sent.last().getString("version") == "")
            check(prefs.getString("keys.talk", null) == "fn")
            repeat(2) { i -> val op = sent.last(); s.acknowledge(ack(op, entry(op.getString("value"), "v$i", i + 1))) }
            check(JSONObject(prefs.getString("bindingSync.pending", "{}") ?: "{}").length() == 0)
            // Offline edit survives process restart, and stale edits lose to a Mac revision.
            s.disconnected(); s.edit("keys.talk", "rcmd", "")
            s = sync(); s.snapshot(snapshot(JSONObject().put("keys.talk", entry("cmd+ctrl", "mac-new", 5))))
            check(sent.last().getString("version") == "v1")
            s.acknowledge(ack(sent.last(), entry("cmd+ctrl", "mac-new", 5), false))
            check(prefs.getString("keys.talk", null) == "cmd+ctrl")
            check(notices.size == 1)
            // An old snapshot cannot roll back a newer acknowledgement.
            s.edit("keys.talk", "rcmd", "")
            s.acknowledge(ack(sent.last(), entry("rcmd", "newer", 7)))
            s.snapshot(snapshot(JSONObject().put("keys.talk", entry("fn", "older", 6))))
            check(prefs.getString("keys.talk", null) == "rcmd")
            // A new Mac snapshot arriving before an old ack must also win.
            s.edit("keys.talk", "fn", "")
            val oldOperation = sent.last()
            s.snapshot(snapshot(JSONObject().put("keys.talk", entry("cmd+shift", "latest", 9))))
            s.acknowledge(ack(oldOperation, entry("fn", "delayed", 8)))
            check(prefs.getString("keys.talk", null) == "cmd+shift")
            // Rapid edits retain one in-flight operation and rebase the next only after its ack.
            s.edit("keys.talk", "fn", "")
            val first = sent.last()
            s.edit("keys.talk", "rcmd", "")
            check(sent.last().getString("operation") == first.getString("operation"))
            s.acknowledge(ack(first, entry("fn", "first", 10)))
            check(sent.last().getString("version") == "first")
            check(sent.last().getString("value") == "rcmd")
            s.acknowledge(ack(sent.last(), entry("rcmd", "second", 11)))
            // Reset is a tombstone and removes the actual phone preference.
            s.edit("keys.talk", null, "")
            check(sent.last().isNull("value"))
            s.acknowledge(ack(sent.last(), entry(null, "reset", 12)))
            check(!prefs.contains("keys.talk"))
            check(JSONObject(prefs.getString("bindingSync.pending", "{}") ?: "{}").length() == 0)
            clear()
            result.putString("stream", "PASS: migration, offline persistence, conflict, reordered snapshot/ack, rapid edits, reset (6 scenarios)\n")
            finish(Activity.RESULT_OK, result)
        } catch (error: Throwable) {
            result.putString("stream", "FAIL: " + error.stackTraceToString())
            finish(Activity.RESULT_CANCELED, result)
        }
    }
}
