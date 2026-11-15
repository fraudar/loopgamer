package org.loopgamer.emulator

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.locks.LockSupport

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler {

    companion object {
        private const val METHOD_CHANNEL = "org.loopgamer.libretro/methods"
        private const val EVENT_CHANNEL = "org.loopgamer.libretro/events"

        // Bits padrão Libretro Joypad
        private const val RETRO_B = 1 shl 0
        private const val RETRO_Y = 1 shl 1
        private const val RETRO_SELECT = 1 shl 2
        private const val RETRO_START = 1 shl 3
        private const val RETRO_UP = 1 shl 4
        private const val RETRO_DOWN = 1 shl 5
        private const val RETRO_LEFT = 1 shl 6
        private const val RETRO_RIGHT = 1 shl 7
        private const val RETRO_A = 1 shl 8
        private const val RETRO_X = 1 shl 9
        private const val RETRO_L = 1 shl 10
        private const val RETRO_R = 1 shl 11
        private const val RETRO_L2 = 1 shl 12
        private const val RETRO_R2 = 1 shl 13

        init {
            System.loadLibrary("libretro_jni")
        }
    }

    private var surfaceEntry: TextureRegistry.SurfaceTextureEntry? = null
    private var surfaceTexture: SurfaceTexture? = null
    private var renderSurface: Surface? = null
    private var audioTrack: AudioTrack? = null
    private var emuThread: Thread? = null
    private val isRunning = AtomicBoolean(false)
    private val isPaused = AtomicBoolean(false)
    private val vsyncEnabledFlag = AtomicBoolean(false)
    private val audioEnabledFlag = AtomicBoolean(true)
    @Volatile private var masterVolumeLevel: Float = 0.85f
    @Volatile private var fastForwardMultiplier: Double = 1.0
    private val touchJoypadMask = AtomicInteger(0)
    private val hardwareJoypadMask = AtomicInteger(0)
    private val leftStickX = AtomicInteger(0)
    private val leftStickY = AtomicInteger(0)
    private var currentSavesDir: String = ""
    private var currentRomBaseName: String = "slot"
    private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).setMethodCallHandler(this)

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                eventSink = events
            }

            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startLibretroSession" -> {
                val corePath = call.argument<String>("corePath")
                val romPath = call.argument<String>("romPath")
                val systemDir = call.argument<String>("systemDir") ?: filesDir.absolutePath
                val savesDir = call.argument<String>("savesDir") ?: filesDir.absolutePath
                val scale = (call.argument<Int>("resolutionScale") ?: 2).coerceIn(1, 10)
                val frameSkip = (call.argument<Int>("frameSkip") ?: 0).coerceIn(0, 3)
                val vsync = call.argument<Boolean>("vsyncEnabled") ?: false
                val audEnabled = call.argument<Boolean>("audioEnabled") ?: true
                val audVolume = (call.argument<Double>("masterVolume") ?: 0.85).toFloat().coerceIn(0f, 1f)
                val softwareRendering = call.argument<Boolean>("softwareRendering") ?: false
                val gpuBackend = call.argument<String>("gpuBackend") ?: ""
                // 0 = OpenGL ES, 1 = software CPU, 2 = Vulkan
                val backendMode = when (gpuBackend.lowercase()) {
                    "vulkan" -> 2
                    "software" -> 1
                    else -> if (softwareRendering) 1 else 0
                }
                val screenScale = (call.argument<Int>("screenScale") ?: 1).coerceIn(1, 4)
                val frameDup = call.argument<Boolean>("frameDup") ?: false
                val coreOptions = call.argument<String>("coreOptions")
                val customDriverDir = call.argument<String>("customDriverDir") ?: ""
                val customDriverName = call.argument<String>("customDriverName") ?: ""
                val adrenoTurbo = call.argument<Boolean>("adrenoTurbo") ?: false

                if (corePath.isNullOrEmpty() || romPath.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "corePath e romPath são obrigatórios.", null)
                    return
                }

                val hookLibDir = applicationInfo.nativeLibraryDir + "/"
                val tmpDir = File(cacheDir, "adrenotools_tmp").apply { mkdirs() }.absolutePath + "/"
                nativeSetCustomVulkanDriver(
                    hookLibDir,
                    tmpDir,
                    customDriverDir,
                    customDriverName,
                    adrenoTurbo
                )

                vsyncEnabledFlag.set(vsync)
                audioEnabledFlag.set(audEnabled)
                masterVolumeLevel = audVolume
                nativeSetFrameSkip(frameSkip)
                nativeSetGpuBackend(backendMode)
                nativeSetFrameDup(frameDup)
                nativeSetVsync(vsync)
                nativeSetCoreOptions(coreOptions ?: "")

                stopLibretroLoop()

                val entry = flutterEngine!!.renderer.createSurfaceTexture()
                val st = entry.surfaceTexture()
                surfaceTexture = st
                val platform = call.argument<String>("platform")?.lowercase() ?: ""
                val romLower = romPath.lowercase()
                val isPsp = platform == "psp" ||
                    romLower.endsWith(".iso") ||
                    romLower.endsWith(".cso") ||
                    romLower.endsWith(".pbp") ||
                    romLower.endsWith(".chd")
                val initW = ((if (isPsp) 480 else 320) * screenScale).coerceIn(64, 4096)
                val initH = ((if (isPsp) 272 else 240) * screenScale).coerceIn(64, 4096)
                st.setDefaultBufferSize(initW, initH)
                val surface = Surface(st)

                surfaceEntry = entry
                renderSurface = surface
                currentSavesDir = savesDir
                currentRomBaseName = File(romPath).nameWithoutExtension

                val loaded = nativeLoadCoreAndRom(
                    corePath,
                    romPath,
                    systemDir,
                    savesDir,
                    surface
                )
                if (!loaded) {
                    surface.release()
                    entry.release()
                    surfaceEntry = null
                    renderSurface = null
                    surfaceTexture = null
                    result.error("CORE_LOAD_FAILED", "Falha ao carregar motor ou ROM.", null)
                    return
                }

                // Define o tamanho real do buffer do SurfaceTexture conforme a
                // resolução base do jogo × escala de tela escolhida (evita a
                // imagem esticada/borrada de antes).
                val baseW = nativeGetFrameWidth().coerceAtLeast(64)
                val baseH = nativeGetFrameHeight().coerceAtLeast(64)
                val targetW = (baseW * screenScale).coerceAtMost(4096)
                val targetH = (baseH * screenScale).coerceAtMost(4096)
                if (targetW != initW || targetH != initH) {
                    st.setDefaultBufferSize(targetW, targetH)
                }

                initAudioTrack(nativeGetSampleRate())
                applyAudioVolume()
                startLibretroLoop(File(corePath).name)
                result.success(entry.id())
            }

            "setAudioConfig" -> {
                val enabled = call.argument<Boolean>("enabled") ?: true
                val vol = (call.argument<Double>("volume") ?: 0.85).toFloat().coerceIn(0f, 1f)
                audioEnabledFlag.set(enabled)
                masterVolumeLevel = vol
                applyAudioVolume()
                result.success(null)
            }

            "setPerformanceConfig" -> {
                val skip = (call.argument<Int>("frameSkip") ?: 0).coerceIn(0, 3)
                val vsync = call.argument<Boolean>("vsyncEnabled") ?: false
                val dup = call.argument<Boolean>("frameDup") ?: false
                nativeSetFrameSkip(skip)
                nativeSetFrameDup(dup)
                nativeSetVsync(vsync)
                vsyncEnabledFlag.set(vsync)
                result.success(null)
            }

            "setFastForward" -> {
                val speed = (call.argument<Double>("speed") ?: 1.0).coerceIn(1.0, 8.0)
                fastForwardMultiplier = speed
                result.success(null)
            }

            "setTurboConfig" -> {
                val mask = call.argument<Int>("turboMask") ?: 0
                val period = call.argument<Int>("halfPeriodFrames") ?: 3
                nativeSetTurboConfig(mask, period)
                result.success(null)
            }

            "updateInput" -> {
                val mask = call.argument<Int>("joypadMask") ?: 0
                val lx = call.argument<Int>("leftX") ?: 0
                val ly = call.argument<Int>("leftY") ?: 0
                touchJoypadMask.set(mask)
                leftStickX.set(lx)
                leftStickY.set(ly)
                pushCombinedInputToNative()
                result.success(null)
            }

            "saveState" -> {
                val slot = call.argument<Int>("slot") ?: 0
                val statePath = "$currentSavesDir/${currentRomBaseName}_slot$slot.state"
                val ok = nativeSaveState(statePath)
                result.success(ok)
            }

            "loadState" -> {
                val slot = call.argument<Int>("slot") ?: 0
                val statePath = "$currentSavesDir/${currentRomBaseName}_slot$slot.state"
                val ok = nativeLoadState(statePath)
                result.success(ok)
            }

            "setPaused" -> {
                val paused = call.argument<Boolean>("paused") ?: false
                isPaused.set(paused)
                result.success(null)
            }

            "stopLibretroSession" -> {
                stopLibretroLoop()
                result.success(null)
            }

            "getInstalledEdenPackage" -> {
                result.success(findInstalledEdenPackage())
            }

            "launchRomInEden" -> {
                val romPath = call.argument<String>("romPath")
                if (romPath.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "Caminho da ROM ausente.", null)
                    return
                }
                val romFile = File(romPath)
                if (!romFile.exists()) {
                    result.error("FILE_NOT_FOUND", "ROM não encontrada em disco.", null)
                    return
                }
                val edenPkg = findInstalledEdenPackage()
                if (edenPkg == null) {
                    result.error("EDEN_NOT_INSTALLED", "Emulador Eden não está instalado neste dispositivo.", null)
                    return
                }
                try {
                    val uri = FileProvider.getUriForFile(
                        this,
                        "$packageName.fileprovider",
                        romFile
                    )
                    grantUriPermission(edenPkg, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    val launchIntent = Intent(Intent.ACTION_VIEW).apply {
                        setDataAndType(uri, "application/octet-stream")
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                        component = ComponentName(
                            edenPkg,
                            "org.yuzu.yuzu_emu.activities.EmulationActivity"
                        )
                    }
                    try {
                        startActivity(launchIntent)
                    } catch (_: Exception) {
                        val fallbackIntent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/octet-stream")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
                            setPackage(edenPkg)
                        }
                        startActivity(fallbackIntent)
                    }
                    result.success(true)
                } catch (e: Exception) {
                    result.error("EDEN_LAUNCH_FAILED", e.message ?: "Falha ao abrir no Eden.", null)
                }
            }

            "openExternalUrl" -> {
                val url = call.argument<String>("url")
                if (url.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "URL vazia.", null)
                    return
                }
                try {
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.error("OPEN_URL_FAILED", e.message ?: "Não foi possível abrir link.", null)
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun findInstalledEdenPackage(): String? {
        val candidates = listOf(
            "dev.eden.eden_emulator",
            "com.miHoYo.Yuanshen",
            "dev.legacy.eden_emulator",
            "org.yuzu.yuzu_emu"
        )
        for (pkg in candidates) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    packageManager.getPackageInfo(
                        pkg,
                        PackageManager.PackageInfoFlags.of(0)
                    )
                } else {
                    @Suppress("DEPRECATION")
                    packageManager.getPackageInfo(pkg, 0)
                }
                return pkg
            } catch (_: Exception) {
            }
        }
        return null
    }

    private fun applyAudioVolume() {
        val effectiveVol = if (audioEnabledFlag.get()) masterVolumeLevel else 0f
        audioTrack?.setVolume(effectiveVol)
    }

    private fun initAudioTrack(sampleRateHz: Int) {
        val validRate = if (sampleRateHz in 8000..96000) sampleRateHz else 44100
        val minBuf = AudioTrack.getMinBufferSize(
            validRate,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_GAME)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setSampleRate(validRate)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_STEREO)
                    .build()
            )
            .setBufferSizeInBytes((minBuf * 2).coerceAtLeast(8192))
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
            .apply { play() }
    }

    private fun pushCombinedInputToNative() {
        val mergedMask = touchJoypadMask.get() or hardwareJoypadMask.get()
        nativeUpdateInput(
            mergedMask,
            leftStickX.get().toShort(),
            leftStickY.get().toShort()
        )
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        val bit = mapKeyCodeToRetroBit(keyCode)
        if (bit != 0 && isRunning.get()) {
            hardwareJoypadMask.set(hardwareJoypadMask.get() or bit)
            pushCombinedInputToNative()
            mainHandler.post { eventSink?.success(mapOf("event" to "hardwareGamepadActive")) }
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        val bit = mapKeyCodeToRetroBit(keyCode)
        if (bit != 0 && isRunning.get()) {
            hardwareJoypadMask.set(hardwareJoypadMask.get() and bit.inv())
            pushCombinedInputToNative()
            return true
        }
        return super.onKeyUp(keyCode, event)
    }

    override fun onGenericMotionEvent(event: MotionEvent?): Boolean {
        if (event != null &&
            (event.source and InputDevice.SOURCE_JOYSTICK) == InputDevice.SOURCE_JOYSTICK &&
            isRunning.get()
        ) {
            val lx = (event.getAxisValue(MotionEvent.AXIS_X) * 32767f).toInt().coerceIn(-32767, 32767)
            val ly = (event.getAxisValue(MotionEvent.AXIS_Y) * 32767f).toInt().coerceIn(-32767, 32767)
            leftStickX.set(lx)
            leftStickY.set(ly)
            pushCombinedInputToNative()
            mainHandler.post { eventSink?.success(mapOf("event" to "hardwareGamepadActive")) }
            return true
        }
        return super.onGenericMotionEvent(event)
    }

    private fun mapKeyCodeToRetroBit(keyCode: Int): Int {
        return when (keyCode) {
            KeyEvent.KEYCODE_BUTTON_A -> RETRO_B
            KeyEvent.KEYCODE_BUTTON_B -> RETRO_A
            KeyEvent.KEYCODE_BUTTON_X -> RETRO_Y
            KeyEvent.KEYCODE_BUTTON_Y -> RETRO_X
            KeyEvent.KEYCODE_BUTTON_L1 -> RETRO_L
            KeyEvent.KEYCODE_BUTTON_R1 -> RETRO_R
            KeyEvent.KEYCODE_BUTTON_L2 -> RETRO_L2
            KeyEvent.KEYCODE_BUTTON_R2 -> RETRO_R2
            KeyEvent.KEYCODE_BUTTON_SELECT -> RETRO_SELECT
            KeyEvent.KEYCODE_BUTTON_START -> RETRO_START
            KeyEvent.KEYCODE_DPAD_UP -> RETRO_UP
            KeyEvent.KEYCODE_DPAD_DOWN -> RETRO_DOWN
            KeyEvent.KEYCODE_DPAD_LEFT -> RETRO_LEFT
            KeyEvent.KEYCODE_DPAD_RIGHT -> RETRO_RIGHT
            else -> 0
        }
    }

    private fun startLibretroLoop(coreFileName: String) {
        isRunning.set(true)
        isPaused.set(false)

        emuThread = Thread({
            try {
                Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY)
            } catch (_: Throwable) {}

            val baseTargetFps = nativeGetTargetFps().takeIf { it > 10.0 } ?: 60.0
            val pcmBuffer = ShortArray(4096)
            var frames = 0
            var lastFpsTimestamp = System.nanoTime()
            var nextFrameDeadline = System.nanoTime()

            while (isRunning.get()) {
                val frameStart = System.nanoTime()
                val currentFf = fastForwardMultiplier
                val effectiveTargetFps = (baseTargetFps * currentFf).coerceIn(10.0, 480.0)
                val targetFrameNs = (1_000_000_000.0 / effectiveTargetFps).toLong().coerceAtLeast(300_000L)

                if (!isPaused.get()) {
                    nativeStepFrame()
                    while (true) {
                        val samplesRead = nativeDrainAudioBuffer(pcmBuffer)
                        if (samplesRead <= 0) break
                        if (audioEnabledFlag.get()) {
                            audioTrack?.write(pcmBuffer, 0, samplesRead, AudioTrack.WRITE_NON_BLOCKING)
                        }
                    }
                    frames++
                } else {
                    LockSupport.parkNanos(16_000_000L)
                    nextFrameDeadline = System.nanoTime()
                }

                val now = System.nanoTime()
                if (now - lastFpsTimestamp >= 750_000_000L) {
                    val fps = (frames * 1_000_000_000.0 / (now - lastFpsTimestamp)).coerceAtMost(effectiveTargetFps)
                    val frameTimeMs = if (fps > 0.5) 1000.0 / fps else 16.6
                    val w = nativeGetFrameWidth()
                    val h = nativeGetFrameHeight()
                    frames = 0
                    lastFpsTimestamp = now

                    mainHandler.post {
                        eventSink?.success(
                            mapOf(
                                "fps" to fps,
                                "frameTimeMs" to frameTimeMs,
                                "width" to w,
                                "height" to h,
                                "coreName" to coreFileName
                            )
                        )
                    }
                }

                nextFrameDeadline += targetFrameNs
                val remainingNs = nextFrameDeadline - System.nanoTime()
                if (remainingNs > 800_000L) {
                    LockSupport.parkNanos(remainingNs - 300_000L)
                } else if (remainingNs <= 0L) {
                    nextFrameDeadline = System.nanoTime()
                }
            }
        }, "LibretroTurboThread").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    private fun stopLibretroLoop() {
        if (isRunning.getAndSet(false)) {
            emuThread?.join(1500)
            emuThread = null
            nativeUnloadCore()
        }
        audioTrack?.stop()
        audioTrack?.release()
        audioTrack = null
        renderSurface?.release()
        renderSurface = null
        surfaceTexture = null
        surfaceEntry?.release()
        surfaceEntry = null
    }

    override fun onDestroy() {
        stopLibretroLoop()
        super.onDestroy()
    }

    private external fun nativeLoadCoreAndRom(
        corePath: String,
        romPath: String,
        systemDir: String,
        savesDir: String,
        surface: Surface
    ): Boolean

    private external fun nativeStepFrame()
    private external fun nativeSetFrameSkip(skip: Int)
    private external fun nativeSetCoreOptions(options: String)
    private external fun nativeSetCustomVulkanDriver(
        hookLibDir: String,
        tmpDir: String,
        driverDir: String,
        driverName: String,
        turbo: Boolean
    )
    private external fun nativeSetGpuBackend(mode: Int)
    private external fun nativeSetRendererMode(software: Boolean)
    private external fun nativeSetFrameDup(enabled: Boolean)
    private external fun nativeSetVsync(enabled: Boolean)
    private external fun nativeSetTurboConfig(mask: Int, period: Int)
    private external fun nativeDrainAudioBuffer(outPcm: ShortArray): Int
    private external fun nativeGetSampleRate(): Int
    private external fun nativeGetTargetFps(): Double
    private external fun nativeUpdateInput(joypadMask: Int, leftX: Short, leftY: Short)
    private external fun nativeSaveState(path: String): Boolean
    private external fun nativeLoadState(path: String): Boolean
    private external fun nativeGetFrameWidth(): Int
    private external fun nativeGetFrameHeight(): Int
    private external fun nativeUnloadCore()
}
