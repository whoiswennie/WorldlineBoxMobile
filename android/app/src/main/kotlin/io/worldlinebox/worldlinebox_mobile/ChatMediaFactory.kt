package io.worldlinebox.worldlinebox_mobile

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.graphics.Color
import android.net.Uri
import android.view.View
import android.view.ViewGroup
import android.view.Gravity
import android.widget.Button
import android.widget.FrameLayout
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONObject

class ChatMediaFactory(private val activity: Activity, private val messenger: BinaryMessenger) :
    PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    @SuppressLint("SetJavaScriptEnabled")
    override fun create(context: Context, id: Int, args: Any?): PlatformView {
        val fields = args as? Map<*, *> ?: emptyMap<String, Any>()
        val url = fields["url"] as? String ?: ""
        val music = fields["music"] == true
        val uri = Uri.parse(url)
        val valid = uri.scheme == "https" && uri.userInfo == null && uri.port == -1 &&
            if (music) uri.host == "music.126.net" || uri.host?.endsWith(".music.126.net") == true
            else uri.host == "player.bilibili.com" && uri.path == "/player.html"
        val channel = MethodChannel(messenger, "worldlinebox/chat-media/$id")
        var live = true
        fun notify(event: String) = activity.runOnUiThread { if (live) channel.invokeMethod(event, null) }
        var fullscreen: Dialog? = null
        val web = WebView(context).apply {
            setBackgroundColor(if (music) Color.WHITE else Color.BLACK)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = !music
            settings.allowContentAccess = false
            settings.allowFileAccess = false
            settings.mediaPlaybackRequiresUserGesture = false
            settings.setSupportMultipleWindows(true)
            settings.javaScriptCanOpenWindowsAutomatically = false
            webViewClient = object : WebViewClient() {
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                    request.isForMainFrame || request.url.scheme != "https"
                override fun onPageFinished(view: WebView, loadedUrl: String) {
                    if (music || loadedUrl != url) return
                    // Run from a real tap in the player document, so its own fullscreen control
                    // receives user activation and owns both entry and exit.
                    view.evaluateJavascript("""(() => {
                        if (document.getElementById('wlb-fullscreen')) return;
                        const button = document.createElement('button');
                        button.id = 'wlb-fullscreen'; button.textContent = '全屏';
                        button.style.cssText = 'position:fixed;right:8px;top:8px;z-index:2147483647;color:white;background:#202026cc;border:none;border-radius:5px;padding:6px 10px';
                        button.onclick = () => {
                            const control = document.querySelector('.bpx-player-ctrl-full, [role="button"][aria-label="全屏"]');
                            if (control) control.click();
                            else (document.querySelector('video') || document.documentElement).requestFullscreen();
                        };
                        document.body.appendChild(button);
                        document.addEventListener('fullscreenchange', () => button.hidden = !!document.fullscreenElement);
                    })()""", null)
                }
                override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
                    if (request.isForMainFrame) notify("error")
                }
            }
            webChromeClient = object : WebChromeClient() {
                override fun onShowCustomView(view: View, callback: CustomViewCallback) {
                    if (fullscreen != null) { callback.onCustomViewHidden(); return }
                    val dialog = Dialog(activity, android.R.style.Theme_Black_NoTitleBar_Fullscreen)
                    fullscreen = dialog
                    val frame = FrameLayout(activity)
                    frame.addView(view, FrameLayout.LayoutParams(-1, -1))
                    frame.addView(Button(activity).apply {
                        text = "退出全屏"
                        setOnClickListener { dialog.dismiss() }
                    }, FrameLayout.LayoutParams(-2, -2, Gravity.TOP or Gravity.END))
                    dialog.setContentView(frame)
                    dialog.setOnDismissListener {
                        (view.parent as? ViewGroup)?.removeView(view)
                        fullscreen = null
                        callback.onCustomViewHidden()
                    }
                    dialog.show()
                }
                override fun onHideCustomView() { fullscreen?.dismiss() }
            }
        }
        if (!valid) web.post { notify("error") }
        else if (music) {
            // Only this bundled audio document receives the two event callbacks.
            web.addJavascriptInterface(object {
                @JavascriptInterface fun ended() { notify("ended") }
                @JavascriptInterface fun failed() { notify("error") }
            }, "CardAudio")
            val source = JSONObject.quote(url).replace("<", "\\u003c")
            web.loadDataWithBaseURL(null, """<!doctype html><meta name="viewport" content="width=device-width,initial-scale=1">
                <style>*{box-sizing:border-box}body{margin:0;display:grid;align-items:center;height:100vh}audio{width:100%}</style>
                <audio controls autoplay controlslist="nodownload noremoteplayback"></audio><script>
                const audio=document.querySelector('audio');audio.onended=()=>CardAudio.ended();
                audio.onerror=()=>CardAudio.failed();audio.src=$source;</script>""", "text/html", "utf-8", null)
        } else {
            // Request the desktop embed, which supplies the in-page controls on narrow screens too.
            val chrome = Regex("Chrome/[0-9.]+").find(web.settings.userAgentString)?.value ?: "Chrome/131.0.0.0"
            web.settings.userAgentString = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) $chrome Safari/537.36"
            web.settings.useWideViewPort = true
            web.settings.loadWithOverviewMode = true
            web.loadUrl(url)
        }
        return object : PlatformView {
            override fun getView(): View = web
            override fun dispose() {
                live = false
                fullscreen?.dismiss()
                web.stopLoading()
                web.removeJavascriptInterface("CardAudio")
                web.loadUrl("about:blank")
                web.destroy()
            }
        }
    }
}
