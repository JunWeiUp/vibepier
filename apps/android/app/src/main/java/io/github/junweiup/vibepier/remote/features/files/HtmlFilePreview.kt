package io.github.junweiup.vibepier.remote.features.files

import android.annotation.SuppressLint
import android.content.Context
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import java.io.ByteArrayInputStream

/** A document-only renderer: inline scripts/styles/images, no app bridge, files or network. */
@SuppressLint("SetJavaScriptEnabled", "ViewConstructor") // Code-created document renderer; external access is blocked.
internal class HtmlFilePreview(context: Context, html: String) : WebView(context) {
    init {
        settings.apply {
            javaScriptEnabled = true
            allowFileAccess = false
            allowContentAccess = false
            blockNetworkLoads = true
            domStorageEnabled = false
            databaseEnabled = false
            mixedContentMode = WebSettings.MIXED_CONTENT_NEVER_ALLOW
            javaScriptCanOpenWindowsAutomatically = false
            setSupportMultipleWindows(true)
            setGeolocationEnabled(false)
            cacheMode = WebSettings.LOAD_NO_CACHE
            useWideViewPort = true
            loadWithOverviewMode = true
            builtInZoomControls = true
            displayZoomControls = false
        }
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                val url = request.url
                return !(url.scheme == "https" && url.host == "vibepier-preview.invalid" &&
                    url.path == "/" && url.query == null && url.fragment != null)
            }
            override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
                // data/blob resources stay inside the current document; everything else is denied.
                if (request.url.scheme in setOf("data", "blob")) return null
                return WebResourceResponse("text/plain", "UTF-8", 403, "Blocked", emptyMap(), ByteArrayInputStream(ByteArray(0)))
            }
        }
        setDownloadListener { _, _, _, _, _ -> }
        val policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; " +
            "img-src data: blob:; font-src data:; media-src data: blob:; connect-src 'none'; " +
            "frame-src 'none'; object-src 'none'; form-action 'none'; base-uri 'none'"
        // A prepended policy applies before any document script and cannot be loosened by later meta tags.
        loadDataWithBaseURL("https://vibepier-preview.invalid/", "<!doctype html><meta charset=\"utf-8\">" +
            "<meta http-equiv=\"Content-Security-Policy\" content=\"$policy\">" + html, "text/html", "UTF-8", null)
    }

    fun release() {
        stopLoading()
        onPause()
        removeAllViews()
        destroy()
    }
}
