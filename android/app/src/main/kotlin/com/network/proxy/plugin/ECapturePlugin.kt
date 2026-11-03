package com.network.proxy.plugin

import android.content.Context
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
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
    private lateinit var appContext: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
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
                    val forceStop = call.argument<Boolean>("forceStop") ?: true
                    val libs = (call.argument<List<*>>("libs"))?.map { it.toString() }
                    io.execute {
                        try {
                            reply(result, start(path, wsUrl, pkg, uid, libs, launch, forceStop))
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
                    val pid = call.argument<Number>("pid")?.toInt()
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
        val maps = pids.flatMap { scanMaps(it) }.distinct()
        val apk = scanApkLibs(pkg)
        val merged = mergeLibPaths(maps, apk)
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
        launch: Boolean,
        forceStop: Boolean
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

        val requested = libsArg?.map { it.trim() }?.filter { it.startsWith("/") && it.contains(".so") } ?: emptyList()
        val requestedPrivate = requested.filter { path ->
            val info = classifyLib(path)
            info["hook"] == true && info["kind"] != "conscrypt" && info["kind"] != "system"
        }
        val discovered = if (requestedPrivate.isEmpty()) discover(pkg) else emptyMap<String, Any>()
        if (requestedPrivate.isEmpty() && discovered["ok"] != true) {
            return mapOf(
                "ok" to false,
                "error" to (discovered["error"]?.toString() ?: "discover failed"),
                "package" to pkg,
                "uid" to uid
            )
        }
        val hookFromDiscover = (discovered["hookLibs"] as? List<*>)?.map { it.toString() } ?: emptyList()
        val classified = (discovered["libs"] as? List<*>)?.mapNotNull { item ->
            (item as? Map<*, *>)?.let { it["path"].toString() to it }
        }?.toMap() ?: emptyMap()
        val hookPaths = requestedPrivate.ifEmpty { hookFromDiscover }
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
        val copy = execSu("cp ${shQuote(src.absolutePath)} $DEST && chmod 755 $DEST", timeoutSec = 20)
        if (copy.exit != 0) {
            return mapOf("ok" to false, "error" to "copy binary failed: ${copy.stderr.ifEmpty { copy.stdout }}")
        }

        if (forceStop) {
            execSu("am force-stop $pkg", timeoutSec = 8)
        }

        val quotedWs = shQuote(wsUrl)
        val cmd = StringBuilder()
        cmd.append(": > $LOG; : > $PID_FILE; ")
        cmd.append("echo package=$pkg uid=$uid forceStop=$forceStop >> $LOG; ")
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
        cmd.append("echo __ECAP_PIDS__; cat $PID_FILE")
        val started = execSu(cmd.toString(), timeoutSec = 30)
        if (started.exit != 0) {
            return mapOf("ok" to false, "error" to "start failed: ${started.stderr.ifEmpty { started.stdout }}", "libs" to hookPaths)
        }
        val pids = parseMarkedInts(started.stdout, "__ECAP_PIDS__")
        if (pids.isEmpty()) {
            return mapOf("ok" to false, "error" to "empty pid", "libs" to hookPaths)
        }
        Thread.sleep(if (forceStop) 4000 else 1000)
        val launched = if (launch) launchApp(pkg) else pidsOf(pkg).isNotEmpty()
        if (!isRunning()) {
            val log = execSu("tail -n 60 $LOG", timeoutSec = 5).stdout
            return mapOf("ok" to false, "error" to "process exited: $log", "pid" to pids.first(), "libs" to hookPaths, "launched" to launched)
        }
        return mapOf(
            "ok" to true,
            "package" to pkg,
            "uid" to uid,
            "pid" to pids.first(),
            "pids" to pids,
            "libs" to hookPaths,
            "launched" to launched,
            "forceStop" to forceStop
        )
    }

    private fun launchApp(pkg: String): Boolean {
        execSu("monkey -p $pkg -c android.intent.category.LAUNCHER 1", timeoutSec = 10)
        Thread.sleep(800)
        if (pidsOf(pkg).isNotEmpty()) return true
        val component = execSu(
            "cmd package resolve-activity --brief $pkg 2>/dev/null",
            timeoutSec = 5
        ).stdout.lineSequence().map { it.trim() }.lastOrNull { it.contains('/') && !it.contains(' ') }.orEmpty()
        if (component.contains("/")) {
            execSu("am start -n ${shQuote(component)}", timeoutSec = 10)
            Thread.sleep(800)
            if (pidsOf(pkg).isNotEmpty()) return true
        }
        execSu("am start -a android.intent.action.MAIN -c android.intent.category.LAUNCHER $pkg", timeoutSec = 10)
        Thread.sleep(800)
        return pidsOf(pkg).isNotEmpty()
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
        uidFromPackageManager(pkg)?.let { return it }

        val listed = execSu("pm list packages -U $pkg", timeoutSec = 8)
        parseUidFromPmList(listed.stdout, pkg)?.let { return it }

        val dumped = execSu("dumpsys package $pkg 2>/dev/null | grep -m 1 'userId='", timeoutSec = 8)
        parseUserId(dumped.stdout)?.let { return it }

        for (path in listOf("/data/user/0/$pkg", "/data/data/$pkg")) {
            val out = execSu("stat -c %u $path", timeoutSec = 5)
            parseFirstInt(out.stdout)?.let { return it }
        }
        return null
    }

    private fun uidFromPackageManager(pkg: String): Int? {
        return applicationInfoOrNull(pkg)?.uid?.takeIf { it > 0 }
    }

    private fun applicationInfoOrNull(pkg: String): ApplicationInfo? {
        val pm = packageManagerOrNull() ?: return null
        return try {
            pm.getApplicationInfo(pkg, 0)
        } catch (_: PackageManager.NameNotFoundException) {
            null
        } catch (_: Exception) {
            null
        }
    }

    private fun packageManagerOrNull(): PackageManager? {
        if (isActivityAttached()) return activity.packageManager
        if (::appContext.isInitialized) return appContext.packageManager
        return null
    }

    private fun parseUidFromPmList(stdout: String, pkg: String): Int? {
        val pattern = Regex("(?:^|\\s)package:${Regex.escape(pkg)}\\s+uid:\\s*(\\d+)")
        return pattern.find(stdout)?.groupValues?.get(1)?.toIntOrNull()?.takeIf { it > 0 }
    }

    private fun parseUserId(stdout: String): Int? {
        return Regex("(?:^|\\s)userId=(\\d+)").find(stdout)?.groupValues?.get(1)?.toIntOrNull()?.takeIf { it > 0 }
    }

    private fun parseFirstInt(stdout: String): Int? {
        for (line in stdout.lineSequence()) {
            val token = line.trim()
            if (token.isNotEmpty() && token.all { it.isDigit() }) {
                return token.toIntOrNull()?.takeIf { it > 0 }
            }
        }
        return null
    }

    private fun pidsOf(pkg: String): List<Int> {
        val out = execSu(
            "echo __ECAP_APP_PIDS__; " +
                "for p in /proc/[0-9]*; do " +
                "c=\$(tr '\\0' ' ' < \"\$p/cmdline\" 2>/dev/null); " +
                "case \"\$c\" in $pkg|$pkg:*|$pkg' '*) echo \${p#/proc/};; esac; " +
                "done; pidof $pkg 2>/dev/null",
            timeoutSec = 8
        )
        return parseMarkedInts(out.stdout, "__ECAP_APP_PIDS__").distinct()
    }

    private fun scanMaps(pid: Int): List<String> {
        val out = execSu(
            "awk '\$6 ~ /^\\// && \$6 ~ /\\.so/ {print \$6}' /proc/$pid/maps 2>/dev/null | sort -u | grep -iE 'libssl|conscrypt|cronet|libflutter|libsscronet|boring'",
            timeoutSec = 10
        )
        return pathLines(out.stdout)
    }

    private fun scanApkLibs(pkg: String): List<String> {
        val dirs = linkedSetOf<String>()
        val app = applicationInfoOrNull(pkg)
        app?.nativeLibraryDir?.takeIf { it.isNotEmpty() }?.let { dirs.add(it) }
        app?.sourceDir?.let { src ->
            File(src).parentFile?.absolutePath?.let { parent ->
                dirs.add("$parent/lib/arm64")
                dirs.add("$parent/lib/arm")
                dirs.add("$parent/lib/arm64-v8a")
                dirs.add("$parent/lib/armeabi-v7a")
            }
        }
        val findCmd = if (dirs.isNotEmpty()) {
            val quoted = dirs.joinToString(" ") { shQuote(it) }
            "for d in $quoted; do ls -1 \"\$d\"/*.so 2>/dev/null; done"
        } else {
            apkLibGlob(pkg)
        }
        val out = execSu("$findCmd | grep -iE 'libssl|boring|cronet|flutter'", timeoutSec = 8)
        val found = pathLines(out.stdout)
        if (found.isNotEmpty()) return found
        return pathLines(execSu("${apkLibGlob(pkg)} | grep -iE 'libssl|boring|cronet|flutter'", timeoutSec = 8).stdout)
    }

    private fun apkLibGlob(pkg: String): String {
        return "ls -1 /data/app/*/$pkg-*/lib/arm64/*.so /data/app/*/$pkg-*/lib/arm/*.so " +
            "/data/app/$pkg-*/lib/arm64/*.so /data/app/$pkg-*/lib/arm/*.so 2>/dev/null"
    }

    private fun mergeLibPaths(maps: List<String>, apk: List<String>): List<String> {
        val found = (maps + apk).distinct()
        val classified = found.associateWith { classifyLib(it) }
        fun kindOf(path: String) = classified[path]?.get("kind")?.toString()
        val privateHook = found.filter {
            classified[it]?.get("hook") == true && kindOf(it) != "conscrypt" && kindOf(it) != "system"
        }
        if (privateHook.isNotEmpty()) {
            return found.filter { kindOf(it) != "conscrypt" && kindOf(it) != "system" }
        }
        return found
    }

    private fun parseMarkedInts(stdout: String, marker: String): List<Int> {
        val idx = stdout.lastIndexOf(marker)
        val slice = if (idx >= 0) stdout.substring(idx + marker.length) else stdout
        return slice.lineSequence()
            .map { it.trim() }
            .mapNotNull { it.toIntOrNull()?.takeIf { n -> n > 0 } }
            .toList()
    }

    private fun pathLines(stdout: String): List<String> {
        return stdout.lineSequence()
            .map { it.trim() }
            .filter { it.startsWith("/") && it.contains(".so") && !it.contains("!") && !it.contains("*") }
            .distinct()
            .toList()
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
        val uid = uidOfPid(pid) ?: return null
        val packageManager = packageManagerOrNull() ?: return null
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
        return parseFirstInt(out.stdout)
    }

    private fun shQuote(value: String): String = "'" + value.replace("'", "'\\''") + "'"

    private fun reply(result: MethodChannel.Result, value: Any?) {
        main.post { result.success(value) }
    }

    private fun execSu(command: String, timeoutSec: Long): CmdResult {
        val process = ProcessBuilder("su", "-c", command)
            .redirectErrorStream(true)
            .start()
        val stdout = process.inputStream.bufferedReader().readText()
        val finished = process.waitFor(timeoutSec, TimeUnit.SECONDS)
        if (!finished) {
            process.destroyForcibly()
            return CmdResult(-1, stdout, "timeout")
        }
        return CmdResult(process.exitValue(), stdout, stdout)
    }

    private data class CmdResult(val exit: Int, val stdout: String, val stderr: String)
}
