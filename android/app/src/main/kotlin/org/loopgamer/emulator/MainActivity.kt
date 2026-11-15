package org.loopgamer.emulator

import android.graphics.SurfaceTexture
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.util.Log
import android.view.InputDevice
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.locks.LockSupport

class MainActivity : FlutterActivity(), MethodChannel.MethodCallHandler {

    companion object {
        private const val TAG = "LoopGamerMain"
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

        // Plataformas que só possuem 1 gatilho de cada lado (L e R, sem L2/R2),
        // como PSP (God of War), GBA, SNES e Nintendo DS.
        private val SINGLE_TRIGGER_PLATFORMS = setOf(
            "psp",
            "gba",
            "snes",
            "nds",
            "gbc",
            "gb",
            "nes",
            "gamegear",
            "mastersystem",
            "md",
            "pce"
        )

        init {
            System.loadLibrary("libretro_jni")
        }
    }

    @Volatile private var surfaceEntry: TextureRegistry.SurfaceTextureEntry? = null
    @Volatile private var surfaceTexture: SurfaceTexture? = null
    @Volatile private var renderSurface: Surface? = null
    @Volatile private var audioTrack: AudioTrack? = null
    private val audioLock = Any()

    @Volatile private var emuThread: Thread? = null
    private val isRunning = AtomicBoolean(false)
    private val isPaused = AtomicBoolean(false)
    private val userPaused = AtomicBoolean(false)
    private val lifecyclePaused = AtomicBoolean(false)
    private val isActivityResumed = AtomicBoolean(false)
    private val sessionToken = AtomicLong(0)

    private val nativeExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "LibretroNativeIO")
    }

    private val vsyncEnabledFlag = AtomicBoolean(false)
    private val audioEnabledFlag = AtomicBoolean(true)
    @Volatile private var masterVolumeLevel: Float = 0.85f
    @Volatile private var fastForwardMultiplier: Double = 1.0
    private val touchJoypadMask = AtomicInteger(0)
    private val hardwareJoypadMask = AtomicInteger(0)
    private val hardwareAxisMask = AtomicInteger(0)
    @Volatile private var singleTriggerPlatform: Boolean = false
    private val leftStickX = AtomicInteger(0)
    private val leftStickY = AtomicInteger(0)
    @Volatile private var currentSavesDir: String = ""
    @Volatile private var currentRomBaseName: String = "slot"
    @Volatile private var currentSessionTitle: String = "LoopGamer"
    @Volatile private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL
        ).also { it.setMethodCallHandler(this) }

        eventChannel = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL
        ).also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    eventSink = events
                }

                override fun onCancel(arguments: Any?) {
                    eventSink = null
                }
            })
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startLibretroSession" -> {
                val corePath = call.argument<String>("corePath")
                val romPath = call.argument<String>("romPath")
                val systemDir = call.argument<String>("systemDir") ?: filesDir.absolutePath
                val savesDir = call.argument<String>("savesDir") ?: filesDir.absolutePath
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
                val coreOptions = call.argument<String>("coreOptions") ?: ""
                val customDriverDir = call.argument<String>("customDriverDir") ?: ""
                val customDriverName = call.argument<String>("customDriverName") ?: ""
                val adrenoTurbo = call.argument<Boolean>("adrenoTurbo") ?: false
                val freedrenoPreset = call.argument<String>("freedrenoPreset") ?: ""
                val platform = call.argument<String>("platform")?.lowercase() ?: ""

                if (corePath.isNullOrEmpty() || romPath.isNullOrEmpty()) {
                    result.error("INVALID_ARGS", "corePath e romPath são obrigatórios.", null)
                    return
                }

                val engine = flutterEngine
                if (engine == null) {
                    result.error("ENGINE_UNAVAILABLE", "FlutterEngine indisponível.", null)
                    return
                }

                val entry = engine.renderer.createSurfaceTexture()
                val st = entry.surfaceTexture()
                val romLower = romPath.lowercase()
                val isPs1 = platform == "ps1" || platform == "psx"
                val isPsp = platform == "psp" ||
                    romLower.endsWith(".iso") ||
                    romLower.endsWith(".cso") ||
                    (!isPs1 && (romLower.endsWith(".pbp") || romLower.endsWith(".chd")))

                val initW = when {
                    isPsp -> (480 * screenScale).coerceIn(64, 4096)
                    isPs1 -> maxOf(320 * screenScale, 640).coerceIn(64, 4096)
                    else -> (320 * screenScale).coerceIn(64, 4096)
                }
                val initH = when {
                    isPsp -> (272 * screenScale).coerceIn(64, 4096)
                    isPs1 -> maxOf(240 * screenScale, 480).coerceIn(64, 4096)
                    else -> (240 * screenScale).coerceIn(64, 4096)
                }
                st.setDefaultBufferSize(initW, initH)
                val surface = Surface(st)

                val hookLibDir = applicationInfo.nativeLibraryDir + "/"
                val tmpDir = File(cacheDir, "adrenotools_tmp").apply { mkdirs() }.absolutePath + "/"

                val myToken = sessionToken.incrementAndGet()
                // Sinaliza interrupção imediata para qualquer loop em execução
                isRunning.set(false)

                nativeExecutor.execute {
                    stopLibretroLoopInternal()

                    if (sessionToken.get() != myToken || isFinishing || isDestroyed) {
                        surface.release()
                        releaseSurfaceEntryOnMain(entry)
                        mainHandler.post {
                            result.error("SESSION_CANCELLED", "Sessão cancelada antes de iniciar.", null)
                        }
                        return@execute
                    }

                    // Opções nativas aplicadas APÓS parar a sessão anterior
                    nativeSetCustomVulkanDriver(
                        hookLibDir,
                        tmpDir,
                        customDriverDir,
                        customDriverName,
                        adrenoTurbo
                    )
                    nativeSetFreedrenoPreset(freedrenoPreset)

                    vsyncEnabledFlag.set(vsync)
                    audioEnabledFlag.set(audEnabled)
                    masterVolumeLevel = audVolume
                    nativeSetFrameSkip(frameSkip)
                    nativeSetGpuBackend(backendMode)
                    nativeSetFrameDup(frameDup)
                    nativeSetVsync(vsync)
                    nativeSetCoreOptions(coreOptions)

                    singleTriggerPlatform = platform in SINGLE_TRIGGER_PLATFORMS || isPsp
                    touchJoypadMask.set(0)
                    hardwareJoypadMask.set(0)
                    hardwareAxisMask.set(0)
                    leftStickX.set(0)
                    leftStickY.set(0)
                    userPaused.set(false)
                    lifecyclePaused.set(!isActivityResumed.get())
                    isPaused.set(lifecyclePaused.get())

                    surfaceEntry = entry
                    surfaceTexture = st
                    renderSurface = surface
                    currentSavesDir = savesDir
                    val romBase = File(romPath).nameWithoutExtension
                    currentRomBaseName = romBase
                    currentSessionTitle = romBase.ifBlank { File(corePath).name }

                    val loaded = try {
                        nativeLoadCoreAndRom(
                            corePath,
                            romPath,
                            systemDir,
                            savesDir,
                            surface
                        )
                    } catch (t: Throwable) {
                        Log.e(TAG, "Erro em nativeLoadCoreAndRom", t)
                        false
                    }

                    if (!loaded) {
                        stopLibretroLoopInternal()
                        mainHandler.post {
                            result.error("CORE_LOAD_FAILED", "Falha ao carregar motor ou ROM.", null)
                        }
                        return@execute
                    }

                    if (sessionToken.get() != myToken || isFinishing || isDestroyed) {
                        stopLibretroLoopInternal()
                        mainHandler.post {
                            result.error("SESSION_CANCELLED", "Sessão cancelada durante carregamento.", null)
                        }
                        return@execute
                    }

                    // Define o tamanho real do buffer do SurfaceTexture conforme a
                    // resolução base do jogo × escala de tela escolhida (PS1 garante
                    // mínimo de 640x480 para telas entrelaçadas de boot/menu).
                    val baseW = nativeGetFrameWidth().coerceAtLeast(64)
                    val baseH = nativeGetFrameHeight().coerceAtLeast(64)
                    val targetW = maxOf(baseW * screenScale, if (isPs1) 640 else 64).coerceAtMost(4096)
                    val targetH = maxOf(baseH * screenScale, if (isPs1) 480 else 64).coerceAtMost(4096)
                    if (targetW != initW || targetH != initH) {
                        st.setDefaultBufferSize(targetW, targetH)
                    }

                    isPaused.set(userPaused.get() || lifecyclePaused.get() || !isActivityResumed.get())
                    initAudioTrack(nativeGetSampleRate())
                    applyAudioVolume()
                    startLibretroLoop(File(corePath).name)

                    mainHandler.post {
                        syncPauseAndServiceState()
                        result.success(entry.id())
                    }
                }
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
                val savesDir = currentSavesDir
                val romBase = currentRomBaseName
                if (savesDir.isEmpty()) {
                    result.success(false)
                    return
                }
                val statePath = "$savesDir/${romBase}_slot$slot.state"
                nativeExecutor.execute {
                    val ok = try {
                        nativeSaveState(statePath)
                    } catch (t: Throwable) {
                        Log.e(TAG, "Erro em nativeSaveState", t)
                        false
                    }
                    mainHandler.post { result.success(ok) }
                }
            }

            "loadState" -> {
                val slot = call.argument<Int>("slot") ?: 0
                val savesDir = currentSavesDir
                val romBase = currentRomBaseName
                if (savesDir.isEmpty()) {
                    result.success(false)
                    return
                }
                val statePath = "$savesDir/${romBase}_slot$slot.state"
                nativeExecutor.execute {
                    val ok = try {
                        nativeLoadState(statePath)
                    } catch (t: Throwable) {
                        Log.e(TAG, "Erro em nativeLoadState", t)
                        false
                    }
                    mainHandler.post { result.success(ok) }
                }
            }

            "setPaused" -> {
                val paused = call.argument<Boolean>("paused") ?: false
                userPaused.set(paused)
                syncPauseAndServiceState()
                result.success(null)
            }

            "stopLibretroSession" -> {
                sessionToken.incrementAndGet()
                isRunning.set(false)
                userPaused.set(false)
                lifecyclePaused.set(false)
                isPaused.set(false)
                EmulationForegroundService.stop(this)
                nativeExecutor.execute {
                    stopLibretroLoopInternal()
                    mainHandler.post { result.success(null) }
                }
            }

            else -> result.notImplemented()
        }
    }

    private fun syncPauseAndServiceState() {
        val running = isRunning.get()
        val effectivePaused = userPaused.get() || lifecyclePaused.get() || !isActivityResumed.get()
        isPaused.set(effectivePaused)

        synchronized(audioLock) {
            val track = audioTrack
            if (track != null && track.state == AudioTrack.STATE_INITIALIZED) {
                try {
                    if (!running || effectivePaused) {
                        if (track.playState == AudioTrack.PLAYSTATE_PLAYING) {
                            track.pause()
                            track.flush()
                        }
                    } else {
                        if (track.playState != AudioTrack.PLAYSTATE_PLAYING) {
                            track.play()
                        }
                    }
                } catch (e: IllegalStateException) {
                    Log.w(TAG, "AudioTrack state transition ignorado: ${e.message}")
                }
            }
        }

        if (running) {
            if (isActivityResumed.get() && !EmulationForegroundService.isActive) {
                EmulationForegroundService.start(this, currentSessionTitle, effectivePaused)
            } else if (EmulationForegroundService.isActive) {
                EmulationForegroundService.update(this, currentSessionTitle, effectivePaused)
            }
        } else {
            EmulationForegroundService.stop(this)
        }
    }

    private fun applyAudioVolume() {
        val effectiveVol = if (audioEnabledFlag.get()) masterVolumeLevel else 0f
        synchronized(audioLock) {
            val track = audioTrack
            if (track != null && track.state == AudioTrack.STATE_INITIALIZED) {
                try {
                    track.setVolume(effectiveVol)
                } catch (_: IllegalStateException) {
                }
            }
        }
    }

    private fun releaseAudioTrack() {
        synchronized(audioLock) {
            val track = audioTrack
            audioTrack = null
            if (track != null) {
                try {
                    if (track.state == AudioTrack.STATE_INITIALIZED) {
                        val underruns = track.underrunCount
                        if (underruns > 0) {
                            Log.i(TAG, "AudioTrack underruns na sessão: $underruns")
                        }
                        if (track.playState == AudioTrack.PLAYSTATE_PLAYING ||
                            track.playState == AudioTrack.PLAYSTATE_PAUSED
                        ) {
                            track.stop()
                        }
                    }
                } catch (_: Throwable) {
                } finally {
                    try {
                        track.release()
                    } catch (_: Throwable) {
                    }
                }
            }
        }
    }

    private fun initAudioTrack(sampleRateHz: Int) {
        releaseAudioTrack()
        val validRate = if (sampleRateHz in 8000..96000) sampleRateHz else 44100
        val rawMinBuf = AudioTrack.getMinBufferSize(
            validRate,
            AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        if (rawMinBuf <= 0) {
            Log.w(
                TAG,
                "AudioTrack.getMinBufferSize retornou erro ($rawMinBuf) para ${validRate}Hz; usando fallback"
            )
        }
        val safeMinBuf = if (rawMinBuf > 0) {
            rawMinBuf
        } else {
            ((validRate / 10) * 4).coerceAtLeast(8192)
        }
        // Margem de 4x o buffer mínimo (mínimo 16 KB, alinhado a 4 bytes/frame stereo PCM16)
        val targetBufferBytes = (((safeMinBuf * 4).coerceAtLeast(16384)) + 3) and 3.inv()

        val built = try {
            AudioTrack.Builder()
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
                .setBufferSizeInBytes(targetBufferBytes)
                .setTransferMode(AudioTrack.MODE_STREAM)
                .build()
        } catch (t: Throwable) {
            Log.e(TAG, "Falha ao construir AudioTrack", t)
            null
        }

        if (built == null || built.state != AudioTrack.STATE_INITIALIZED) {
            Log.e(TAG, "AudioTrack não inicializado (state=${built?.state})")
            try {
                built?.release()
            } catch (_: Throwable) {
            }
            return
        }

        synchronized(audioLock) {
            audioTrack = built
            if (!isPaused.get()) {
                try {
                    built.play()
                } catch (e: IllegalStateException) {
                    Log.w(TAG, "Falha ao iniciar AudioTrack.play(): ${e.message}")
                }
            }
        }
    }

    private fun writeAudioNonBlocking(pcmBuffer: ShortArray, sampleCount: Int) {
        synchronized(audioLock) {
            val track = audioTrack ?: return
            if (track.state != AudioTrack.STATE_INITIALIZED ||
                track.playState != AudioTrack.PLAYSTATE_PLAYING
            ) {
                return
            }

            var offset = 0
            var remaining = sampleCount
            var zeroWriteRetries = 0
            while (remaining > 0 && isRunning.get() && !isPaused.get()) {
                val written = try {
                    track.write(pcmBuffer, offset, remaining, AudioTrack.WRITE_NON_BLOCKING)
                } catch (_: IllegalStateException) {
                    AudioTrack.ERROR_INVALID_OPERATION
                }

                if (written < 0) {
                    if (written == AudioTrack.ERROR_DEAD_OBJECT) {
                        Log.w(TAG, "AudioTrack ERROR_DEAD_OBJECT ($written); liberando track")
                        audioTrack = null
                        try {
                            track.release()
                        } catch (_: Throwable) {
                        }
                    } else {
                        Log.w(TAG, "AudioTrack.write falhou com código $written")
                    }
                    break
                }

                if (written == 0) {
                    if (fastForwardMultiplier > 1.15 || zeroWriteRetries >= 1) {
                        break
                    }
                    zeroWriteRetries++
                    LockSupport.parkNanos(350_000L)
                    continue
                }

                offset += written
                remaining -= written
            }
        }
    }

    private fun pushCombinedInputToNative() {
        var mergedMask = touchJoypadMask.get() or hardwareJoypadMask.get() or hardwareAxisMask.get()
        if (singleTriggerPlatform) {
            if ((mergedMask and RETRO_L2) != 0) {
                mergedMask = (mergedMask and RETRO_L2.inv()) or RETRO_L
            }
            if ((mergedMask and RETRO_R2) != 0) {
                mergedMask = (mergedMask and RETRO_R2.inv()) or RETRO_R
            }
        }
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
            mainHandler.post {
                try {
                    eventSink?.success(mapOf("event" to "hardwareGamepadActive"))
                } catch (_: Throwable) {
                }
            }
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
            val lTrig = maxOf(
                event.getAxisValue(MotionEvent.AXIS_LTRIGGER),
                event.getAxisValue(MotionEvent.AXIS_BRAKE)
            )
            val rTrig = maxOf(
                event.getAxisValue(MotionEvent.AXIS_RTRIGGER),
                event.getAxisValue(MotionEvent.AXIS_GAS)
            )
            val hatX = event.getAxisValue(MotionEvent.AXIS_HAT_X)
            val hatY = event.getAxisValue(MotionEvent.AXIS_HAT_Y)

            var axisBits = 0
            if (lTrig >= 0.30f) axisBits = axisBits or RETRO_L2
            if (rTrig >= 0.30f) axisBits = axisBits or RETRO_R2
            if (hatX <= -0.5f) axisBits = axisBits or RETRO_LEFT
            if (hatX >= 0.5f) axisBits = axisBits or RETRO_RIGHT
            if (hatY <= -0.5f) axisBits = axisBits or RETRO_UP
            if (hatY >= 0.5f) axisBits = axisBits or RETRO_DOWN

            leftStickX.set(lx)
            leftStickY.set(ly)
            hardwareAxisMask.set(axisBits)
            pushCombinedInputToNative()
            if (kotlin.math.abs(lx) > 3000 || kotlin.math.abs(ly) > 3000 || axisBits != 0) {
                mainHandler.post {
                    try {
                        eventSink?.success(mapOf("event" to "hardwareGamepadActive"))
                    } catch (_: Throwable) {
                    }
                }
            }
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

        emuThread = Thread({
            try {
                try {
                    Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_DISPLAY)
                } catch (_: Throwable) {
                }

                val baseTargetFps = nativeGetTargetFps().takeIf { it > 10.0 } ?: 60.0
                val pcmBuffer = ShortArray(4096)
                var frames = 0
                var lastFpsTimestamp = System.nanoTime()
                var nextFrameDeadline = System.nanoTime()

                while (isRunning.get()) {
                    val currentFf = fastForwardMultiplier
                    val effectiveTargetFps = (baseTargetFps * currentFf).coerceIn(10.0, 480.0)
                    val targetFrameNs = (1_000_000_000.0 / effectiveTargetFps).toLong().coerceAtLeast(300_000L)

                    if (!isPaused.get()) {
                        nativeStepFrame()
                        while (isRunning.get() && !isPaused.get()) {
                            val samplesRead = nativeDrainAudioBuffer(pcmBuffer)
                            if (samplesRead <= 0) break
                            if (audioEnabledFlag.get()) {
                                writeAudioNonBlocking(pcmBuffer, samplesRead)
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
                            try {
                                eventSink?.success(
                                    mapOf(
                                        "fps" to fps,
                                        "frameTimeMs" to frameTimeMs,
                                        "width" to w,
                                        "height" to h,
                                        "coreName" to coreFileName
                                    )
                                )
                            } catch (_: Throwable) {
                            }
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
            } finally {
                try {
                    nativeReleaseRenderThreadContext()
                } catch (_: Throwable) {
                }
            }
        }, "LibretroTurboThread").apply {
            priority = Thread.MAX_PRIORITY
            start()
        }
    }

    private fun releaseSurfaceEntryOnMain(entry: TextureRegistry.SurfaceTextureEntry?) {
        if (entry == null) return
        val releaseAction = Runnable {
            try {
                if (!isDestroyed) {
                    entry.release()
                }
            } catch (_: Throwable) {
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            releaseAction.run()
        } else {
            mainHandler.post(releaseAction)
        }
    }

    private fun releaseRenderSurfaces() {
        val surf = renderSurface
        renderSurface = null
        surfaceTexture = null
        val entry = surfaceEntry
        surfaceEntry = null

        if (surf != null) {
            try {
                surf.release()
            } catch (_: Throwable) {
            }
        }
        releaseSurfaceEntryOnMain(entry)
    }

    private fun stopLibretroLoopInternal() {
        isRunning.set(false)
        val thread = emuThread
        emuThread = null
        if (thread != null) {
            try {
                thread.join(2000)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
            if (thread.isAlive) {
                Log.w(TAG, "LibretroTurboThread não encerrou em 2000ms; interrompendo")
                thread.interrupt()
                try {
                    thread.join(500)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                }
            }
        }

        // Sempre descarrega o core e libera áudio/superfícies fora de `if (isRunning)`
        // para evitar vazamentos caso uma exceção ocorra antes do start do loop.
        try {
            nativeUnloadCore()
        } catch (t: Throwable) {
            Log.e(TAG, "Falha em nativeUnloadCore", t)
        }
        releaseAudioTrack()
        releaseRenderSurfaces()
        EmulationForegroundService.stop(this)
    }

    override fun onResume() {
        super.onResume()
        isActivityResumed.set(true)
        lifecyclePaused.set(false)
        syncPauseAndServiceState()
    }

    override fun onPause() {
        isActivityResumed.set(false)
        lifecyclePaused.set(true)
        if (isRunning.get()) {
            touchJoypadMask.set(0)
            hardwareJoypadMask.set(0)
            hardwareAxisMask.set(0)
            pushCombinedInputToNative()
            syncPauseAndServiceState()
        }
        super.onPause()
    }

    override fun onStop() {
        lifecyclePaused.set(true)
        if (isRunning.get()) {
            syncPauseAndServiceState()
        }
        super.onStop()
    }

    override fun onDestroy() {
        isActivityResumed.set(false)
        sessionToken.incrementAndGet()
        isRunning.set(false)
        EmulationForegroundService.stop(this)

        methodChannel?.setMethodCallHandler(null)
        methodChannel = null
        eventChannel?.setStreamHandler(null)
        eventChannel = null
        eventSink = null

        val latch = CountDownLatch(1)
        try {
            nativeExecutor.execute {
                try {
                    stopLibretroLoopInternal()
                } finally {
                    latch.countDown()
                }
            }
            latch.await(2500, TimeUnit.MILLISECONDS)
        } catch (_: Throwable) {
            stopLibretroLoopInternal()
        }
        nativeExecutor.shutdown()
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
    private external fun nativeReleaseRenderThreadContext()
    private external fun nativeSetFrameSkip(skip: Int)
    private external fun nativeSetCoreOptions(options: String)
    private external fun nativeSetCustomVulkanDriver(
        hookLibDir: String,
        tmpDir: String,
        driverDir: String,
        driverName: String,
        turbo: Boolean
    )
    private external fun nativeSetFreedrenoPreset(preset: String)
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
