package io.worldlinebox.worldlinebox_mobile

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address

/** A bounded DNS-SD lookup on the active LAN. SSH verifies the resolved endpoint. */
@Suppress("DEPRECATION")
class LocalComputerDiscovery(context: Context) {
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val networks = context.getSystemService(ConnectivityManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var scan: Scan? = null

    fun find(name: String?, result: MethodChannel.Result) {
        val hasLan = networks.allNetworks.any {
            val caps = networks.getNetworkCapabilities(it)
            caps != null && (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) || caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN))
        }
        if (!hasLan) { result.success(null); return }
        val current = scan
        if (current != null) current.add(name, result)
        else Scan().also { scan = it; it.add(name, result); it.start() }
    }

    fun close() { scan?.finishAll() }

    // Older Android versions allow only one resolveService call at a time.
    // Share that resolver between nearby browsing and all saved-PC reconnects.
    private inner class Scan : NsdManager.DiscoveryListener {
        private val requests = mutableMapOf<MethodChannel.Result, String?>()
        private val deadlines = mutableMapOf<MethodChannel.Result, Runnable>()
        private val routes = linkedMapOf<String, List<Map<String, Any>>>()
        private val queue = linkedMapOf<String, NsdServiceInfo>()
        private var resolving = false

        fun add(name: String?, result: MethodChannel.Result) {
            requests[result] = name
            val done = Runnable { finish(result) }
            deadlines[result] = done
            main.postDelayed(done, if (name == null) 4800 else 2200)
            if (name != null && matches(name).isNotEmpty()) finish(result)
        }
        private fun matches(name: String?) = routes.filterKeys {
            name == null || it == name || it.startsWith("$name (")
        }.values.flatten()

        private fun finish(result: MethodChannel.Result) {
            if (!requests.containsKey(result)) return
            val name = requests.remove(result)
            deadlines.remove(result)?.let(main::removeCallbacks)
            result.success(matches(name))
            if (requests.isEmpty() && scan === this) {
                scan = null
                runCatching { nsd.stopServiceDiscovery(this) }
            }
        }
        fun finishAll() = requests.keys.toList().forEach(::finish)
        fun start() {
            try { nsd.discoverServices("_worldlinebox._tcp.", NsdManager.PROTOCOL_DNS_SD, this) }
            catch (_: RuntimeException) { finishAll() }
        }
        override fun onServiceFound(service: NsdServiceInfo) {
            main.post {
                if (scan !== this) return@post
                queue[service.serviceName] = service
                resolveNext()
            }
        }
        private fun resolveNext() {
            if (resolving || queue.isEmpty() || scan !== this) return
            resolving = true
            val key = queue.keys.first()
            val service = queue.remove(key)!!
            try {
                nsd.resolveService(service, object : NsdManager.ResolveListener {
                    override fun onResolveFailed(info: NsdServiceInfo, code: Int) {
                        main.postDelayed({
                            resolving = false
                            if (code == NsdManager.FAILURE_ALREADY_ACTIVE) queue[key] = service
                            resolveNext()
                        }, 120)
                    }
                    override fun onServiceResolved(info: NsdServiceInfo) {
                        val addresses = if (android.os.Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
                        val endpoints = addresses.filterIsInstance<Inet4Address>().map {
                            mapOf<String, Any>("host" to it.hostAddress!!, "port" to info.port,
                                "fingerprint" to info.attributes["fingerprint"]?.toString(Charsets.UTF_8).orEmpty(),
                                "name" to info.attributes["name"]?.toString(Charsets.UTF_8).orEmpty())
                        }
                        main.post {
                            routes[key] = endpoints
                            for ((result, name) in requests.toMap()) {
                                if (name != null && matches(name).isNotEmpty()) finish(result)
                            }
                            resolving = false
                            resolveNext()
                        }
                    }
                })
            } catch (_: RuntimeException) { resolving = false; resolveNext() }
        }
        override fun onServiceLost(service: NsdServiceInfo) {
            main.post { queue.remove(service.serviceName); routes.remove(service.serviceName) }
        }
        override fun onDiscoveryStarted(type: String) {}
        override fun onDiscoveryStopped(type: String) {}
        override fun onStartDiscoveryFailed(type: String, code: Int) { main.post { finishAll() } }
        override fun onStopDiscoveryFailed(type: String, code: Int) {}
    }
}
