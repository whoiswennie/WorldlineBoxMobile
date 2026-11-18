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
    private val pending = mutableSetOf<Lookup>()

    fun find(name: String, result: MethodChannel.Result) {
        val hasLan = networks.allNetworks.any {
            val caps = networks.getNetworkCapabilities(it)
            caps != null && (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) || caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN))
        }
        if (!hasLan) {
            result.success(null)
            return
        }
        val lookup = Lookup(name, result)
        pending.add(lookup)
        lookup.start()
    }

    fun close() = pending.toList().forEach { it.finish() }

    private inner class Lookup(val name: String, val result: MethodChannel.Result) : NsdManager.DiscoveryListener {
        private val timeout = Runnable { finish() }
        private var resolving = false
        fun start() {
            main.postDelayed(timeout, 2200)
            try { nsd.discoverServices("_worldlinebox._tcp.", NsdManager.PROTOCOL_DNS_SD, this) }
            catch (_: RuntimeException) { finish() }
        }
        fun finish(addresses: List<Map<String, Any>> = emptyList()) {
            if (!pending.remove(this)) return
            main.removeCallbacks(timeout)
            runCatching { nsd.stopServiceDiscovery(this) }
            result.success(addresses)
        }
        override fun onServiceFound(service: NsdServiceInfo) {
            if (service.serviceName != name && !service.serviceName.startsWith("$name (")) return
            main.post {
                if (this !in pending || resolving) return@post
                resolving = true
                try {
                    nsd.resolveService(service, object : NsdManager.ResolveListener {
                        override fun onResolveFailed(info: NsdServiceInfo, code: Int) { main.post { finish() } }
                        override fun onServiceResolved(info: NsdServiceInfo) {
                            val addresses = if (android.os.Build.VERSION.SDK_INT >= 34) info.hostAddresses else listOfNotNull(info.host)
                            val routes = addresses.filterIsInstance<Inet4Address>().map {
                                mapOf<String, Any>("host" to it.hostAddress!!, "port" to info.port)
                            }
                            main.post { finish(routes) }
                        }
                    })
                } catch (_: RuntimeException) { finish() }
            }
        }
        override fun onDiscoveryStarted(type: String) {}
        override fun onServiceLost(service: NsdServiceInfo) {}
        override fun onDiscoveryStopped(type: String) {}
        override fun onStartDiscoveryFailed(type: String, code: Int) { main.post { finish() } }
        override fun onStopDiscoveryFailed(type: String, code: Int) {}
    }
}
