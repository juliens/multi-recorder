package app.multirecorder.phone

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.WindowManager
import android.widget.Button
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.launch
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Shows the camera and waits for the Mac. The Mac finds the phone with Bonjour (NSD),
 * then starts and stops clips and downloads them over Wi-Fi.
 */
class MainActivity : ComponentActivity() {
    private lateinit var status: TextView
    private lateinit var recorder: CameraRecorder
    private var server: PhoneServer? = null
    private var nsd: NsdManager? = null
    private var registration: NsdManager.RegistrationListener? = null
    private var lastEvent = "Waiting for the Mac"

    private val permissions = arrayOf(Manifest.permission.CAMERA, Manifest.permission.RECORD_AUDIO)

    private val askPermissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        if (hasPermissions()) startEverything() else showStatus("Camera and microphone access are needed.")
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        status = findViewById(R.id.status)
        recorder = CameraRecorder(this, this, findViewById<PreviewView>(R.id.preview))

        findViewById<Button>(R.id.switchCamera).setOnClickListener {
            lifecycleScope.launch {
                runCatching { recorder.switchCamera() }.onFailure { showStatus(it.message ?: "Cannot switch.") }
            }
        }

        if (hasPermissions()) startEverything() else askPermissions.launch(permissions)
    }

    private fun hasPermissions() = permissions.all {
        ContextCompat.checkSelfPermission(this, it) == PackageManager.PERMISSION_GRANTED
    }

    private fun startEverything() {
        lifecycleScope.launch {
            try {
                recorder.start()
            } catch (error: Exception) {
                showStatus("Cannot open the camera: ${error.message}")
                return@launch
            }
            recorder.onChange = { refreshStatus() }
            val server = PhoneServer(recorder) { event -> runOnUiThread { lastEvent = event; refreshStatus() } }
            server.start()
            this@MainActivity.server = server
            advertise(server.port)
            refreshStatus()
        }
    }

    private fun advertise(port: Int) {
        val manager = getSystemService(Context.NSD_SERVICE) as NsdManager
        val info = NsdServiceInfo().apply {
            serviceName = "MultiRecorder ${Build.MODEL}"
            serviceType = SERVICE_TYPE
            setPort(port)
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) {
                Log.i(TAG, "Registered ${info.serviceName}")
            }

            override fun onRegistrationFailed(info: NsdServiceInfo, errorCode: Int) {
                runOnUiThread { showStatus("Cannot announce the phone on the network ($errorCode).") }
            }

            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, errorCode: Int) {}
        }
        manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
        nsd = manager
        registration = listener
    }

    private fun refreshStatus() {
        val port = server?.port ?: return
        val dot = if (recorder.isRecording) "● REC  " else ""
        val live = recorder.liveSettings
        val bind = recorder.bindSettings
        val details = String.format("%.1fx · %d fps · %s", live.zoom, bind.fps, CameraRecorder.orientationName(bind.rotation))
        showStatus("$dot$lastEvent\n$details\n${Build.MODEL} · ${wifiAddress() ?: "no Wi-Fi"}:$port")
    }

    private fun showStatus(text: String) {
        status.text = text
    }

    @Suppress("DEPRECATION")
    private fun wifiAddress(): String? {
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
        val raw = wifi?.connectionInfo?.ipAddress ?: 0
        if (raw != 0) {
            return "${raw and 0xff}.${raw shr 8 and 0xff}.${raw shr 16 and 0xff}.${raw shr 24 and 0xff}"
        }
        return NetworkInterface.getNetworkInterfaces()?.toList()
            ?.flatMap { it.inetAddresses.toList() }
            ?.firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
            ?.hostAddress
    }

    override fun onDestroy() {
        registration?.let { runCatching { nsd?.unregisterService(it) } }
        server?.close()
        recorder.close()
        super.onDestroy()
    }

    companion object {
        private const val TAG = "MultiRecorderPhone"
        const val SERVICE_TYPE = "_mrecphone._tcp"
    }
}
