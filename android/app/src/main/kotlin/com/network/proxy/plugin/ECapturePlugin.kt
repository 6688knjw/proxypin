package com.network.proxy.plugin

import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class ECapturePlugin : AndroidFlutterPlugin() {
    companion object {
        const val CHANNEL = "com.proxy/ecapture"
        const val DEST = "/data/local/tmp/proxypin-dev-ecapture"
        const val LOG = "/data/local/tmp/proxypin-dev-ecapture.log"
        const val PID_FILE = "/data/local/tmp/proxypin-dev-ecapture.pid"
    }

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isRooted" -> io.execute {
                    reply(result, isRooted())
                }
                "abi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a")
                "isRunning" -> io.execute {
                    reply(result, isRunning())
                }
                "start" -> {
                    val path = call.argument<String>("binaryPath")
                    val wsUrl = call.argument<String>("wsUrl") ?: "ws://127.0.0.1:28257"
                    if (path.isNullOrEmpty()) {
                        result.error("INVALID_ARGUMENT", "binaryPath is empty", null)
                        return@setMethodCallHandler
                    }
                    io.execute {
                        try {
                            reply(result, start(path, wsUrl))
                        } catch (e: Exception) {
                            reply(result, mapOf("ok" to false, "error" to (e.message ?: e.toString())))
                        }
                    }
                }
                "stop" -> io.execute {
                    stop()
                    reply(result, null)
                }
                "getProcessByPid" -> {
                    val pid = call.argument<Int>("pid")
                    if (pid == null || pid <= 0) {
                        result.success(null)
                        return@setMethodCallHandler
                    }
                    io.execute {
                        reply(result, getProcessByPid(pid))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isRooted(): Boolean {
        val out = execSu("id", timeoutSec = 8)
        return out.exit == 0 && out.stdout.contains("uid=0")
    }

    private fun isRunning(): Boolean {
        val out = execSu("kill -0 \$(cat $PID_FILE) 2>/dev/null", timeoutSec = 5)
        return out.exit == 0
    }

    private fun start(srcPath: String, wsUrl: String): Map<String, Any> {
        if (!isRooted()) {
            return mapOf("ok" to false, "error" to "device is not rooted")
        }
        val src = File(srcPath)
        if (!src.exists()) {
            return mapOf("ok" to false, "error" to "binary not found: $srcPath")
        }
        stop()
        val copy = execSu("cp '${src.absolutePath}' $DEST && chmod 755 $DEST", timeoutSec = 20)
        if (copy.exit != 0) {
            return mapOf("ok" to false, "error" to "copy binary failed: ${copy.stderr.ifEmpty { copy.stdout }}")
        }
        val quotedWs = wsUrl.replace("'", "'\\''")
        val start = execSu(
            "nohup $DEST tls --ecaptureq='$quotedWs' >$LOG 2>&1 & echo \$! > $PID_FILE; cat $PID_FILE",
            timeoutSec = 15
        )
        if (start.exit != 0) {
            return mapOf("ok" to false, "error" to "start failed: ${start.stderr.ifEmpty { start.stdout }}")
        }
        val pid = start.stdout.trim().lines().lastOrNull()?.trim().orEmpty()
        if (pid.isEmpty()) {
            return mapOf("ok" to false, "error" to "empty pid")
        }
        Thread.sleep(400)
        if (!isRunning()) {
            val log = execSu("tail -n 40 $LOG", timeoutSec = 5).stdout
            return mapOf("ok" to false, "error" to "process exited: $log", "pid" to pid)
        }
        return mapOf("ok" to true, "pid" to pid)
    }

    private fun stop() {
        execSu(
            "if [ -f $PID_FILE ]; then pid=\$(cat $PID_FILE); if [ -n \"\$pid\" ]; then kill \$pid 2>/dev/null; sleep 0.2; kill -0 \$pid 2>/dev/null && kill -9 \$pid 2>/dev/null; fi; fi; " +
                "for pid in \$(pgrep -f $DEST); do cmdline=\$(tr '\\0' ' ' < /proc/\$pid/cmdline 2>/dev/null); case \"\$cmdline\" in $DEST*) kill \$pid 2>/dev/null ;; esac; done; " +
                "rm -f $PID_FILE",
            timeoutSec = 8
        )
    }

    private fun getProcessByPid(pid: Int): ProcessInfo? {
        if (!::activity.isInitialized) return null
        val uid = uidOfPid(pid) ?: return null
        val packageManager = activity.packageManager
        val packages = try {
            packageManager.getPackagesForUid(uid)
        } catch (_: Exception) {
            null
        } ?: return null
        for (pkg in packages) {
            try {
                val app = packageManager.getApplicationInfo(pkg, 0)
                return ProcessInfo.create(packageManager, app, true)
            } catch (_: Exception) {
            }
        }
        return null
    }

    private fun uidOfPid(pid: Int): Int? {
        try {
            val status = File("/proc/$pid/status")
            if (status.canRead()) {
                status.useLines { lines ->
                    for (line in lines) {
                        if (line.startsWith("Uid:")) {
                            return line.substringAfter(':').trim().split(Regex("\\s+")).firstOrNull()?.toIntOrNull()
                        }
                    }
                }
            }
        } catch (_: Exception) {
        }
        val out = execSu("awk '/^Uid:/{print \$2; exit}' /proc/$pid/status", timeoutSec = 5)
        return out.stdout.trim().lines().firstOrNull()?.trim()?.toIntOrNull()
    }

    private fun reply(result: MethodChannel.Result, value: Any?) {
        main.post { result.success(value) }
    }

    private fun execSu(command: String, timeoutSec: Long): CmdResult {
        val process = ProcessBuilder("su", "-c", command)
            .redirectErrorStream(false)
            .start()
        val stdout = process.inputStream.bufferedReader().readText()
        val stderr = process.errorStream.bufferedReader().readText()
        val finished = process.waitFor(timeoutSec, TimeUnit.SECONDS)
        if (!finished) {
            process.destroyForcibly()
            return CmdResult(-1, stdout, stderr.ifEmpty { "timeout" })
        }
        return CmdResult(process.exitValue(), stdout, stderr)
    }

    private data class CmdResult(val exit: Int, val stdout: String, val stderr: String)
}
