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
        const val SYSTEM_SSL = "/apex/com.android.conscrypt/lib64/libssl.so"
    }

    private val io = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "isRooted" -> io.execute { reply(result, isRooted()) }
                "abi" -> result.success(Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a")
                "isRunning" -> io.execute { reply(result, isRunning()) }
                "discover" -> {
                    val pkg = call.argument<String>("package")
                    io.execute {
                        try {
                            reply(result, discover(pkg))
                        } catch (e: Exception) {
                            reply(result, mapOf("ok" to false, "error" to (e.message ?: e.toString())))
                        }
                    }
                }
                "start" -> {
                    val path = call.argument<String>("binaryPath")
                    if (path.isNullOrEmpty()) {
                        result.error("INVALID_ARGUMENT", "binaryPath is empty", null)
                        return@setMethodCallHandler
                    }
                    val wsUrl = call.argument<String>("wsUrl") ?: "ws://127.0.0.1:28257/"
                    val pkg = call.argument<String>("package")
                    val uid = call.argument<Number>("uid")?.toInt()
                    val launch = call.argument<Boolean>("launch") ?: true
                    val libs = (call.argument<List<*>>("libs"))?.map { it.toString() }
                    io.execute {
                        try {
                            reply(result, start(path, wsUrl, pkg, uid, libs, launch))
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
                    io.execute { reply(result, getProcessByPid(pid)) }
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
        val out = execSu(
            "if [ ! -f $PID_FILE ]; then exit 1; fi; " +
                "while read -r pid; do [ -n \"\$pid\" ] && kill -0 \$pid 2>/dev/null && exit 0; done < $PID_FILE; exit 1",
            timeoutSec = 5
        )
        return out.exit == 0
    }

    private fun discover(packageName: String?): Map<String, Any> {
        if (!isRooted()) {
            return mapOf("ok" to false, "error" to "device is not rooted")
        }
        val pkg = packageName?.trim().orEmpty()
        if (pkg.isEmpty() || !pkg.matches(Regex("[A-Za-z0-9._]+"))) {
            return mapOf("ok" to false, "error" to "package is required")
        }
        val uid = uidOfPackage(pkg)
        if (uid == null) {
            return mapOf("ok" to false, "error" to "package not installed: $pkg")
        }
        val pids = pidsOf(pkg)
        val pid = pids.firstOrNull()
        val maps = if (pid != null) scanMaps(pid) else emptyList()
        val apk = scanApkLibs(pkg)
        val merged = (maps + apk + listOfNotNull(systemSslOrNull())).distinct()
        val libs = merged.map { classifyLib(it) }
        val hookable = libs.filter { it["hook"] == true }
        val kinds = libs.map { it["kind"].toString() }.toSet()
        val capturable = hookable.isNotEmpty()
        val reason = when {
            capturable -> null
            kinds.contains("flutter") && !kinds.any { it.contains("ssl") || it == "conscrypt" || it == "boringssl" } ->
                "only libflutter.so; eCapture cannot hook Flutter"
            kinds.contains("cronet") && hookable.isEmpty() ->
                "cronet without libssl; eCapture usually cannot hook it"
            pid == null -> "app is not running; start it once so /proc/pid/maps can be scanned, or pass libs from APK"
            else -> "no libssl/boringssl/conscrypt found"
        }
        return mapOf(
            "ok" to true,
            "package" to pkg,
            "uid" to uid,
            "pid" to (pid ?: 0),
            "pids" to pids,
            "running" to (pid != null),
            "capturable" to capturable,
            "probe" to if (capturable) "tls" else "none",
            "libs" to libs,
            "hookLibs" to hookable.map { it["path"].toString() },
            if (reason != null) "reason" to reason else "reason" to ""
        )
    }

    private fun start(
        srcPath: String,
        wsUrl: String,
        packageName: String?,
        uidArg: Int?,
        libsArg: List<String>?,
        launch: Boolean
    ): Map<String, Any> {
        if (!isRooted()) {
            return mapOf("ok" to false, "error" to "device is not rooted")
        }
        val src = File(srcPath)
        if (!src.exists()) {
            return mapOf("ok" to false, "error" to "binary not found: $srcPath")
        }
        val pkg = packageName?.trim().orEmpty()
        if (pkg.isEmpty() || !pkg.matches(Regex("[A-Za-z0-9._]+"))) {
            return mapOf("ok" to false, "error" to "package is required")
        }
        val uid = uidArg?.takeIf { it > 0 } ?: uidOfPackage(pkg)
            ?: return mapOf("ok" to false, "error" to "package not installed: $pkg")

        val discovered = discover(pkg)
        val hookFromDiscover = (discovered["hookLibs"] as? List<*>)?.map { it.toString() } ?: emptyList()
        val classified = (discovered["libs"] as? List<*>)?.mapNotNull { item ->
            (item as? Map<*, *>)?.let { it["path"].toString() to it }
        }?.toMap() ?: emptyMap()
        val requested = libsArg?.map { it.trim() }?.filter { it.startsWith("/") && it.endsWith(".so") } ?: emptyList()
        val hookPaths = (if (requested.isNotEmpty()) requested else hookFromDiscover)
            .filter { path ->
                val info = classified[path] ?: classifyLib(path)
                info["hook"] == true
            }
            .distinct()
        if (hookPaths.isEmpty()) {
            return mapOf(
                "ok" to false,
                "error" to ((discovered["reason"] as? String)?.ifEmpty { null } ?: "no hookable libssl"),
                "package" to pkg,
                "uid" to uid,
                "libs" to (discovered["libs"] ?: emptyList<Any>())
            )
        }

        stop()
        val copy = execSu("cp '${src.absolutePath}' $DEST && chmod 755 $DEST", timeoutSec = 20)
        if (copy.exit != 0) {
            return mapOf("ok" to false, "error" to "copy binary failed: ${copy.stderr.ifEmpty { copy.stdout }}")
        }

        execSu("am force-stop $pkg", timeoutSec = 8)

        val quotedWs = shQuote(wsUrl)
        val cmd = StringBuilder()
        cmd.append(": > $LOG; : > $PID_FILE; ")
        cmd.append("echo package=$pkg uid=$uid >> $LOG; ")
        for (lib in hookPaths) {
            val info = classified[lib] ?: classifyLib(lib)
            val version = info["sslVersion"] as? String
            cmd.append("echo hook=$lib >> $LOG; ")
            cmd.append("nohup $DEST tls -m text --uid=$uid --libssl=${shQuote(lib)}")
            if (!version.isNullOrEmpty()) {
                cmd.append(" --ssl_version=${shQuote(version)}")
            }
            cmd.append(" --ecaptureq=$quotedWs >>$LOG 2>&1 & echo \$! >> $PID_FILE; ")
        }
        cmd.append("cat $PID_FILE")
        val started = execSu(cmd.toString(), timeoutSec = 30)
        if (started.exit != 0) {
            return mapOf("ok" to false, "error" to "start failed: ${started.stderr.ifEmpty { started.stdout }}", "libs" to hookPaths)
        }
        val pids = started.stdout.trim().lines().map { it.trim() }.filter { it.isNotEmpty() }
        if (pids.isEmpty()) {
            return mapOf("ok" to false, "error" to "empty pid", "libs" to hookPaths)
        }
        Thread.sleep(4000)
        if (launch) {
            execSu("monkey -p $pkg -c android.intent.category.LAUNCHER 1", timeoutSec = 10)
            Thread.sleep(800)
        }
        if (!isRunning()) {
            val log = execSu("tail -n 60 $LOG", timeoutSec = 5).stdout
            return mapOf("ok" to false, "error" to "process exited: $log", "pid" to pids.first(), "libs" to hookPaths)
        }
        return mapOf(
            "ok" to true,
            "package" to pkg,
            "uid" to uid,
            "pid" to pids.first(),
            "pids" to pids,
            "libs" to hookPaths,
            "launched" to launch
        )
    }

    private fun stop() {
        execSu(
            "if [ -f $PID_FILE ]; then while read -r pid; do [ -n \"\$pid\" ] && kill -2 \$pid 2>/dev/null; done < $PID_FILE; sleep 2; " +
                "while read -r pid; do [ -n \"\$pid\" ] && kill -0 \$pid 2>/dev/null && kill -9 \$pid 2>/dev/null; done < $PID_FILE; fi; " +
                "for pid in \$(pgrep -f $DEST); do cmdline=\$(tr '\\0' ' ' < /proc/\$pid/cmdline 2>/dev/null); case \"\$cmdline\" in $DEST*) kill -2 \$pid 2>/dev/null ;; esac; done; " +
                "rm -f $PID_FILE",
            timeoutSec = 12
        )
    }

    private fun uidOfPackage(pkg: String): Int? {
        val out = execSu("stat -c %u /data/data/$pkg", timeoutSec = 5)
        return out.stdout.trim().lines().firstOrNull()?.trim()?.toIntOrNull()
    }

    private fun pidsOf(pkg: String): List<Int> {
        val out = execSu("pidof $pkg", timeoutSec = 5)
        return out.stdout.trim().split(Regex("\\s+")).mapNotNull { it.toIntOrNull() }
    }

    private fun scanMaps(pid: Int): List<String> {
        val out = execSu(
            "awk '\$6 ~ /^\\// && \$6 ~ /\\.so/ {print \$6}' /proc/$pid/maps 2>/dev/null | sort -u | grep -iE 'libssl|conscrypt|cronet|libflutter|libsscronet|boring'",
            timeoutSec = 10
        )
        return out.stdout.lineSequence()
            .map { it.trim() }
            .filter { it.startsWith("/") && it.contains(".so") && !it.contains("!") }
            .distinct()
            .toList()
    }

    private fun scanApkLibs(pkg: String): List<String> {
        val out = execSu(
            "ls -1 /data/app/*/$pkg-*/lib/arm64/*.so /data/app/$pkg-*/lib/arm64/*.so 2>/dev/null | grep -iE 'libssl|boring|cronet|flutter'",
            timeoutSec = 8
        )
        return out.stdout.lineSequence()
            .map { it.trim() }
            .filter { it.startsWith("/") && it.endsWith(".so") }
            .distinct()
            .toList()
    }

    private fun systemSslOrNull(): String? {
        val out = execSu("[ -f $SYSTEM_SSL ] && echo $SYSTEM_SSL", timeoutSec = 3)
        return out.stdout.trim().takeIf { it == SYSTEM_SSL }
    }

    private fun classifyLib(path: String): Map<String, Any?> {
        val name = path.substringAfterLast('/').lowercase()
        val kind: String
        val hook: Boolean
        val sslVersion: String?
        when {
            name.contains("flutter") -> {
                kind = "flutter"
                hook = false
                sslVersion = null
            }
            name.contains("cronet") && !name.contains("ssl") -> {
                kind = "cronet"
                hook = false
                sslVersion = null
            }
            path.startsWith("/apex/com.android.conscrypt/") && name == "libssl.so" -> {
                kind = "conscrypt"
                hook = true
                sslVersion = null
            }
            (path.startsWith("/system/") || path.startsWith("/apex/")) && name.contains("ssl") -> {
                kind = "system"
                hook = true
                sslVersion = null
            }
            name.contains("ssl") || name.contains("boring") -> {
                kind = "boringssl"
                hook = true
                sslVersion = "boringssl 1.1.1"
            }
            else -> {
                kind = "other"
                hook = false
                sslVersion = null
            }
        }
        return mapOf("path" to path, "kind" to kind, "hook" to hook, "sslVersion" to sslVersion)
    }

    private fun getProcessByPid(pid: Int): ProcessInfo? {
        if (!isActivityAttached()) return null
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

    private fun shQuote(value: String): String = "'" + value.replace("'", "'\\''") + "'"

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
