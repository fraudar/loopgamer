package org.loopgamer.emulator

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.SurfaceTexture
import android.hardware.input.InputManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioTrack
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.util.Log
import android.view.InputDevice
import android.view.InputEvent
import android.view.KeyEvent
import android.view.MotionEvent
import android.view.Surface
import android.view.WindowManager
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsControllerCompat
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
        private const val RETRO_L3 = 1 shl 14
        private const val RETRO_R3 = 1 shl 15

        private const val REQ_POST_NOTIFICATIONS = 4105
        private const val GAMEPAD_ACTIVE_THROTTLE_MS = 400L
        private const val UI_MOTION_REPEAT_MS = 180L
        private const val SELECT_HOLD_FAST_FORWARD_MS = 320L

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
    @Volatile private var baseFastForwardMultiplier: Double = 1.0
    @Volatile private var hardwareSelectFastForwardActive: Boolean = false
    @Volatile private var fastForwardMultiplier: Double = 1.0
    private val touchJoypadMask = AtomicInteger(0)
    private val hardwareJoypadMask = AtomicInteger(0)
    private val hardwareAxisMask = AtomicInteger(0)
    @Volatile private var singleTriggerPlatform: Boolean = false
    private val touchLeftStickX = AtomicInteger(0)
    private val touchLeftStickY = AtomicInteger(0)
    private val touchRightStickX = AtomicInteger(0)
    private val touchRightStickY = AtomicInteger(0)
    private val hardwareLeftStickX = AtomicInteger(0)
    private val hardwareLeftStickY = AtomicInteger(0)
    private val hardwareRightStickX = AtomicInteger(0)
    private val hardwareRightStickY = AtomicInteger(0)
    @Volatile private var currentSavesDir: String = ""
    @Volatile private var currentRomBaseName: String = "slot"
    @Volatile private var currentSessionTitle: String = "LoopGamer"
    @Volatile private var eventSink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var methodChannel: MethodChannel? = null
    private var eventChannel: EventChannel? = null
    private var inputManager: InputManager? = null
    private val lastGamepadActiveEmitMs = AtomicLong(-GAMEPAD_ACTIVE_THROTTLE_MS)
    @Volatile private var lastReportedGamepadConnected: Boolean? = null
    private var notificationPermissionRequestedThisSession: Boolean = false

    private var currentUiDirection: String? = null
    private var uiLeftTriggerPressed: Boolean = false
    private var uiRightTriggerPressed: Boolean = false

    private val uiDirectionRepeatRunnable = object : Runnable {
        override fun run() {
            val dir = currentUiDirection ?: return
            if (isRunning.get() && !isPaused.get()) {
                currentUiDirection = null
                return
            }
            emitGamepadUiAction(dir)
            notifyHardwareGamepadActive()
            mainHandler.postDelayed(this, UI_MOTION_REPEAT_MS)
        }
    }

    private val selectHoldFastForwardRunnable = Runnable {
        if (isRunning.get() &&
            !isPaused.get() &&
            (hardwareJoypadMask.get() and RETRO_SELECT) != 0 &&
            baseFastForwardMultiplier < 2.0
        ) {
            hardwareSelectFastForwardActive = true
            updateEffectiveFastForward()
        }
    }

    private val inputDeviceListener = object : InputManager.InputDeviceListener {
        override fun onInputDeviceAdded(deviceId: Int) {
            val dev = InputDevice.getDevice(deviceId)
            val connected = hasConnectedPhysicalGamepad()
            if (isPhysicalGamepadDevice(dev) || connected != lastReportedGamepadConnected) {
                emitHardwareGamepadState(connected = connected, forceEmit = true)
            }
        }

        override fun onInputDeviceRemoved(deviceId: Int) {
            val connected = hasConnectedPhysicalGamepad()
            if (connected != lastReportedGamepadConnected) {
                emitHardwareGamepadState(connected = connected, forceEmit = true)
            }
        }

        override fun onInputDeviceChanged(deviceId: Int) {
            val dev = InputDevice.getDevice(deviceId)
            val connected = hasConnectedPhysicalGamepad()
            if (isPhysicalGamepadDevice(dev) || connected != lastReportedGamepadConnected) {
                emitHardwareGamepadState(connected = connected, forceEmit = true)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        applyEdgeToEdgeAndCutout(touchDecorView = false)
        super.onCreate(savedInstanceState)
        applyEdgeToEdgeAndCutout()
        inputManager = getSystemService(Context.INPUT_SERVICE) as? InputManager
        inputManager?.registerInputDeviceListener(inputDeviceListener, mainHandler)
    }

    private fun applyEdgeToEdgeAndCutout(touchDecorView: Boolean = true) {
        val win = window ?: return
        WindowCompat.setDecorFitsSystemWindows(win, false)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            win.attributes = win.attributes.apply {
                layoutInDisplayCutoutMode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
                } else {
                    WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
                }
            }
        }
        @Suppress("DEPRECATION")
        win.statusBarColor = Color.TRANSPARENT
        @Suppress("DEPRECATION")
        win.navigationBarColor = Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            @Suppress("DEPRECATION")
            win.isStatusBarContrastEnforced = false
            win.isNavigationBarContrastEnforced = false
        }
        if (touchDecorView) {
            WindowInsetsControllerCompat(win, win.decorView).apply {
                isAppearanceLightStatusBars = false
                isAppearanceLightNavigationBars = false
            }
        }
    }

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
                    emitHardwareGamepadState(
                        connected = hasConnectedPhysicalGamepad(),
                        forceEmit = true
                    )
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
                val platform = call.argument<String>("platform")?.trim()?.lowercase() ?: ""
                val explicitSingleTrigger = call.argument<Boolean>("singleTrigger")

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
                val isPs1 = platform in setOf("ps", "ps1", "psx", "playstation")
                val isPsp = platform == "psp" ||
                    (platform.isEmpty() && (romLower.endsWith(".cso") || romLower.endsWith(".pbp")))

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

                    singleTriggerPlatform = explicitSingleTrigger ?: (platform in SINGLE_TRIGGER_PLATFORMS || isPsp)
                    resetAllInputAtomics()
                    resetFastForwardState()
                    mainHandler.post { resetUiGamepadMotionState() }
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
                baseFastForwardMultiplier = speed
                updateEffectiveFastForward()
                result.success(null)
            }

            "setTurboConfig" -> {
                val mask = call.argument<Int>("turboMask") ?: 0
                val period = call.argument<Int>("halfPeriodFrames") ?: 3
                nativeSetTurboConfig(mask, period)
                result.success(null)
            }

            "updateInput" -> {
                val mask = (call.argument<Any>("joypadMask") as? Number)?.toInt() ?: 0
                val lx = (call.argument<Any>("leftX") as? Number)?.toInt() ?: 0
                val ly = (call.argument<Any>("leftY") as? Number)?.toInt() ?: 0
                touchJoypadMask.set(mask)
                touchLeftStickX.set(lx)
                touchLeftStickY.set(ly)
                val rx = (call.argument<Any>("rightX") as? Number)?.toInt()
                val ry = (call.argument<Any>("rightY") as? Number)?.toInt()
                if (rx != null) {
                    touchRightStickX.set(rx)
                }
                if (ry != null) {
                    touchRightStickY.set(ry)
                }
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
                resetUiGamepadMotionState()
                resetFastForwardState()
                resetAllInputAtomics()
                pushCombinedInputToNative()
                EmulationForegroundService.stop(this)
                nativeExecutor.execute {
                    stopLibretroLoopInternal()
                    mainHandler.post { result.success(null) }
                }
            }

            "syncDownloadNotification" -> {
                val activeCount = (call.argument<Any>("activeCount") as? Number)?.toInt() ?: 0
                val queuedCount = (call.argument<Any>("queuedCount") as? Number)?.toInt() ?: 0
                val completedCount = (call.argument<Any>("completedCount") as? Number)?.toInt() ?: 0
                val failedCount = (call.argument<Any>("failedCount") as? Number)?.toInt() ?: 0
                val progressPercent = (call.argument<Any>("progressPercent") as? Number)?.toInt() ?: 0
                val indeterminate = call.argument<Boolean>("indeterminate") ?: false
                val title = call.argument<String>("title") ?: ""
                val detail = call.argument<String>("detail") ?: ""

                if (activeCount > 0 || queuedCount > 0) {
                    val intent = DownloadForegroundService.buildSyncIntent(
                        context = this,
                        activeCount = activeCount,
                        queuedCount = queuedCount,
                        completedCount = completedCount,
                        failedCount = failedCount,
                        progressPercent = progressPercent,
                        indeterminate = indeterminate,
                        title = title,
                        detail = detail,
                        startedAsForeground = true
                    )
                    DownloadForegroundService.hasPendingOrActiveStart = true
                    try {
                        ContextCompat.startForegroundService(this, intent)
                    } catch (t: Throwable) {
                        DownloadForegroundService.hasPendingOrActiveStart = DownloadForegroundService.isActive
                        Log.w(TAG, "Falha ao iniciar/atualizar DownloadForegroundService: ${t.message}")
                    }
                } else {
                    val stopIntent = DownloadForegroundService.buildStopIntent(
                        context = this,
                        completedCount = completedCount,
                        failedCount = failedCount,
                        title = title,
                        detail = detail
                    )
                    if (DownloadForegroundService.isActive || DownloadForegroundService.hasPendingOrActiveStart) {
                        try {
                            startService(stopIntent)
                        } catch (t: Throwable) {
                            Log.w(TAG, "Falha ao parar DownloadForegroundService via intent: ${t.message}")
                            DownloadForegroundService.stopNowAndNotifyCompletion(
                                context = this,
                                completedCount = completedCount,
                                failedCount = failedCount,
                                title = title,
                                detail = detail
                            )
                        }
                    } else {
                        DownloadForegroundService.stopNowAndNotifyCompletion(
                            context = this,
                            completedCount = completedCount,
                            failedCount = failedCount,
                            title = title,
                            detail = detail
                        )
                    }
                }
                result.success(null)
            }

            "requestNotificationPermission" -> {
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
                    result.success(true)
                    return
                }
                val granted = ContextCompat.checkSelfPermission(
                    this,
                    Manifest.permission.POST_NOTIFICATIONS
                ) == PackageManager.PERMISSION_GRANTED
                if (!granted && !notificationPermissionRequestedThisSession) {
                    notificationPermissionRequestedThisSession = true
                    try {
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                            REQ_POST_NOTIFICATIONS
                        )
                    } catch (t: Throwable) {
                        Log.w(TAG, "Falha ao solicitar permissão POST_NOTIFICATIONS: ${t.message}")
                    }
                }
                result.success(granted)
            }

            "getNetworkStatus" -> {
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                val caps = cm?.activeNetwork?.let { cm.getNetworkCapabilities(it) }
                val hasWifi = caps?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
                val hasTransport = hasWifi ||
                    caps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true ||
                    caps?.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) == true
                val hasInternet = hasTransport &&
                    (caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true ||
                        hasWifi)
                result.success(
                    mapOf(
                        "connected" to hasInternet,
                        "wifi" to hasWifi
                    )
                )
            }

            else -> result.notImplemented()
        }
    }

    private fun syncPauseAndServiceState() {
        val running = isRunning.get()
        val effectivePaused = userPaused.get() || lifecyclePaused.get() || !isActivityResumed.get()
        isPaused.set(effectivePaused)

        if (running && effectivePaused) {
            cancelHardwareSelectFastForward()
            resetUiGamepadMotionState()
            resetAllInputAtomics()
            pushCombinedInputToNative()
        } else if (running) {
            resetUiGamepadMotionState()
        }

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

    private fun updateEffectiveFastForward() {
        fastForwardMultiplier = if (hardwareSelectFastForwardActive) {
            maxOf(baseFastForwardMultiplier, 2.0)
        } else {
            baseFastForwardMultiplier
        }
    }

    private fun cancelHardwareSelectFastForward() {
        mainHandler.removeCallbacks(selectHoldFastForwardRunnable)
        if (hardwareSelectFastForwardActive) {
            hardwareSelectFastForwardActive = false
            updateEffectiveFastForward()
        }
    }

    private fun resetFastForwardState() {
        mainHandler.removeCallbacks(selectHoldFastForwardRunnable)
        hardwareSelectFastForwardActive = false
        baseFastForwardMultiplier = 1.0
        updateEffectiveFastForward()
    }

    private fun resetAllInputAtomics() {
        touchJoypadMask.set(0)
        hardwareJoypadMask.set(0)
        hardwareAxisMask.set(0)
        touchLeftStickX.set(0)
        touchLeftStickY.set(0)
        touchRightStickX.set(0)
        touchRightStickY.set(0)
        hardwareLeftStickX.set(0)
        hardwareLeftStickY.set(0)
        hardwareRightStickX.set(0)
        hardwareRightStickY.set(0)
    }

    private fun resetUiGamepadMotionState() {
        mainHandler.removeCallbacks(uiDirectionRepeatRunnable)
        currentUiDirection = null
        uiLeftTriggerPressed = false
        uiRightTriggerPressed = false
    }

    private fun pickCombinedAxis(touchValue: Int, hardwareValue: Int): Short {
        val chosen = if (kotlin.math.abs(hardwareValue) > kotlin.math.abs(touchValue)) {
            hardwareValue
        } else {
            touchValue
        }
        return chosen.coerceIn(-32767, 32767).toShort()
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
        val lx = pickCombinedAxis(touchLeftStickX.get(), hardwareLeftStickX.get())
        val ly = pickCombinedAxis(touchLeftStickY.get(), hardwareLeftStickY.get())
        val rx = pickCombinedAxis(touchRightStickX.get(), hardwareRightStickX.get())
        val ry = pickCombinedAxis(touchRightStickY.get(), hardwareRightStickY.get())
        nativeUpdateInput(mergedMask, lx, ly, rx, ry)
    }

    private fun emitEventOnMain(payload: Map<String, Any>) {
        val send = Runnable {
            try {
                eventSink?.success(payload)
            } catch (_: Throwable) {
            }
        }
        if (Looper.myLooper() == Looper.getMainLooper()) {
            send.run()
        } else {
            mainHandler.post(send)
        }
    }

    private fun emitHardwareGamepadState(connected: Boolean, forceEmit: Boolean) {
        if (!forceEmit && connected == lastReportedGamepadConnected) return
        lastReportedGamepadConnected = connected
        emitEventOnMain(
            mapOf(
                "event" to "hardwareGamepadState",
                "connected" to connected
            )
        )
        if (connected) {
            notifyHardwareGamepadActive(force = true)
        }
    }

    private fun notifyHardwareGamepadActive(force: Boolean = false) {
        val now = SystemClock.elapsedRealtime()
        if (!force) {
            val prev = lastGamepadActiveEmitMs.get()
            if (now - prev < GAMEPAD_ACTIVE_THROTTLE_MS) return
            if (!lastGamepadActiveEmitMs.compareAndSet(prev, now)) return
        } else {
            lastGamepadActiveEmitMs.set(now)
        }
        emitEventOnMain(mapOf("event" to "hardwareGamepadActive"))
    }

    private fun emitGamepadUiAction(action: String) {
        emitEventOnMain(
            mapOf(
                "event" to "gamepadUiAction",
                "action" to action
            )
        )
    }

    private fun isPhysicalGamepadDevice(device: InputDevice?): Boolean {
        if (device == null || device.isVirtual) return false
        if (device.supportsSource(InputDevice.SOURCE_TOUCHSCREEN)) return false
        return device.supportsSource(InputDevice.SOURCE_GAMEPAD) ||
            device.supportsSource(InputDevice.SOURCE_JOYSTICK)
    }

    private fun hasConnectedPhysicalGamepad(): Boolean {
        for (id in InputDevice.getDeviceIds()) {
            val dev = InputDevice.getDevice(id) ?: continue
            if (isPhysicalGamepadDevice(dev)) {
                return true
            }
        }
        return false
    }

    private fun isPhysicalGamepadEvent(event: InputEvent?): Boolean {
        if (event == null || event.isFromSource(InputDevice.SOURCE_TOUCHSCREEN)) {
            return false
        }
        if (event.device?.isVirtual == true) {
            return false
        }
        return event.isFromSource(InputDevice.SOURCE_GAMEPAD) ||
            event.isFromSource(InputDevice.SOURCE_JOYSTICK) ||
            event.isFromSource(InputDevice.SOURCE_DPAD)
    }

    private fun isDirectGamepadKeySource(event: KeyEvent?): Boolean {
        if (event == null || event.deviceId <= 0 || event.device?.isVirtual == true) {
            return false
        }
        return event.isFromSource(InputDevice.SOURCE_GAMEPAD) ||
            event.isFromSource(InputDevice.SOURCE_JOYSTICK)
    }

    private fun applyStickDeadzone(raw: Float, deadzone: Float = 0.12f): Short {
        val absVal = kotlin.math.abs(raw)
        if (absVal < deadzone) return 0
        val scaled = ((absVal - deadzone) / (1f - deadzone)).coerceIn(0f, 1f)
        val signed = if (raw < 0f) -scaled else scaled
        return (signed * 32767f).toInt().coerceIn(-32767, 32767).toShort()
    }

    private fun findMotionRange(
        device: InputDevice?,
        axis: Int,
        source: Int
    ): InputDevice.MotionRange? {
        if (device == null) return null
        return device.getMotionRange(axis, source) ?: device.getMotionRange(axis)
    }

    private fun readRightStickAxes(event: MotionEvent): Pair<Float, Float> {
        val dev = event.device
            ?: return Pair(
                event.getAxisValue(MotionEvent.AXIS_Z),
                event.getAxisValue(MotionEvent.AXIS_RZ)
            )
        val src = event.source
        val zRange = findMotionRange(dev, MotionEvent.AXIS_Z, src)
        val rzRange = findMotionRange(dev, MotionEvent.AXIS_RZ, src)
        val rxRange = findMotionRange(dev, MotionEvent.AXIS_RX, src)
        val ryRange = findMotionRange(dev, MotionEvent.AXIS_RY, src)

        val zIsStick = zRange != null && zRange.min < -0.1f
        val rzIsStick = rzRange != null && rzRange.min < -0.1f
        val rxIsStick = rxRange != null && rxRange.min < -0.1f
        val ryIsStick = ryRange != null && ryRange.min < -0.1f

        return when {
            zIsStick || rzIsStick -> Pair(
                if (zIsStick) event.getAxisValue(MotionEvent.AXIS_Z) else 0f,
                if (rzIsStick) event.getAxisValue(MotionEvent.AXIS_RZ) else 0f
            )
            rxIsStick || ryIsStick -> Pair(
                if (rxIsStick) event.getAxisValue(MotionEvent.AXIS_RX) else 0f,
                if (ryIsStick) event.getAxisValue(MotionEvent.AXIS_RY) else 0f
            )
            else -> Pair(0f, 0f)
        }
    }

    private fun readAnalogTriggers(event: MotionEvent): Pair<Float, Float> {
        var lTrig = maxOf(
            event.getAxisValue(MotionEvent.AXIS_LTRIGGER),
            event.getAxisValue(MotionEvent.AXIS_BRAKE)
        )
        var rTrig = maxOf(
            event.getAxisValue(MotionEvent.AXIS_RTRIGGER),
            event.getAxisValue(MotionEvent.AXIS_GAS)
        )
        val dev = event.device
        if (dev != null) {
            val src = event.source
            val hasExplicitTriggers =
                findMotionRange(dev, MotionEvent.AXIS_LTRIGGER, src) != null ||
                    findMotionRange(dev, MotionEvent.AXIS_BRAKE, src) != null ||
                    findMotionRange(dev, MotionEvent.AXIS_RTRIGGER, src) != null ||
                    findMotionRange(dev, MotionEvent.AXIS_GAS, src) != null
            if (!hasExplicitTriggers) {
                val zRange = findMotionRange(dev, MotionEvent.AXIS_Z, src)
                val rzRange = findMotionRange(dev, MotionEvent.AXIS_RZ, src)
                if (zRange != null && zRange.min >= 0f) {
                    lTrig = maxOf(lTrig, event.getAxisValue(MotionEvent.AXIS_Z))
                }
                if (rzRange != null && rzRange.min >= 0f) {
                    rTrig = maxOf(rTrig, event.getAxisValue(MotionEvent.AXIS_RZ))
                }
            }
        }
        return Pair(lTrig, rTrig)
    }

    private fun handleHardwareRetroKeyDown(bit: Int, repeatCount: Int) {
        hardwareJoypadMask.set(hardwareJoypadMask.get() or bit)
        pushCombinedInputToNative()
        notifyHardwareGamepadActive()
        if (bit == RETRO_SELECT && repeatCount == 0) {
            mainHandler.removeCallbacks(selectHoldFastForwardRunnable)
            mainHandler.postDelayed(selectHoldFastForwardRunnable, SELECT_HOLD_FAST_FORWARD_MS)
        }
    }

    private fun handleHardwareRetroKeyUp(bit: Int) {
        hardwareJoypadMask.set(hardwareJoypadMask.get() and bit.inv())
        pushCombinedInputToNative()
        if (bit == RETRO_SELECT) {
            cancelHardwareSelectFastForward()
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.keyCode == KeyEvent.KEYCODE_BUTTON_MODE &&
            !event.isFromSource(InputDevice.SOURCE_TOUCHSCREEN) &&
            event.device?.isVirtual != true
        ) {
            if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                emitGamepadUiAction("guide")
                notifyHardwareGamepadActive()
            }
            return true
        }

        if (isPhysicalGamepadEvent(event)) {
            if (isRunning.get() && !isPaused.get()) {
                val bit = mapKeyCodeToRetroBit(event.keyCode, event)
                if (bit != 0) {
                    when (event.action) {
                        KeyEvent.ACTION_DOWN -> handleHardwareRetroKeyDown(bit, event.repeatCount)
                        KeyEvent.ACTION_UP -> handleHardwareRetroKeyUp(bit)
                    }
                    return true
                }
            } else {
                val uiAction = when {
                    event.keyCode == KeyEvent.KEYCODE_BACK && isDirectGamepadKeySource(event) -> "select"
                    event.keyCode == KeyEvent.KEYCODE_MENU && isDirectGamepadKeySource(event) -> "start"
                    event.keyCode == KeyEvent.KEYCODE_MEDIA_RECORD && isDirectGamepadKeySource(event) -> "select"
                    else -> mapGenericHidKeyToUiAction(event.keyCode)
                }
                if (uiAction != null) {
                    if (event.action == KeyEvent.ACTION_DOWN && event.repeatCount == 0) {
                        emitGamepadUiAction(uiAction)
                        notifyHardwareGamepadActive()
                    }
                    return true
                }
                notifyHardwareGamepadActive()
            }
        }
        return super.dispatchKeyEvent(event)
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (isRunning.get() && !isPaused.get() && isPhysicalGamepadEvent(event)) {
            val bit = mapKeyCodeToRetroBit(keyCode, event)
            if (bit != 0) {
                handleHardwareRetroKeyDown(bit, event?.repeatCount ?: 0)
                return true
            }
        }
        return super.onKeyDown(keyCode, event)
    }

    override fun onKeyUp(keyCode: Int, event: KeyEvent?): Boolean {
        if (isRunning.get() && !isPaused.get() && isPhysicalGamepadEvent(event)) {
            val bit = mapKeyCodeToRetroBit(keyCode, event)
            if (bit != 0) {
                handleHardwareRetroKeyUp(bit)
                return true
            }
        }
        return super.onKeyUp(keyCode, event)
    }

    override fun onGenericMotionEvent(event: MotionEvent?): Boolean {
        if (event != null && isPhysicalGamepadEvent(event)) {
            if (event.action == MotionEvent.ACTION_CANCEL) {
                if (isRunning.get() && !isPaused.get()) {
                    hardwareLeftStickX.set(0)
                    hardwareLeftStickY.set(0)
                    hardwareRightStickX.set(0)
                    hardwareRightStickY.set(0)
                    hardwareAxisMask.set(0)
                    pushCombinedInputToNative()
                } else {
                    resetUiGamepadMotionState()
                }
                return super.onGenericMotionEvent(event)
            }

            if (event.action == MotionEvent.ACTION_MOVE) {
                val (lTrig, rTrig) = readAnalogTriggers(event)
                val hatX = event.getAxisValue(MotionEvent.AXIS_HAT_X)
                val hatY = event.getAxisValue(MotionEvent.AXIS_HAT_Y)
                val rawLx = event.getAxisValue(MotionEvent.AXIS_X)
                val rawLy = event.getAxisValue(MotionEvent.AXIS_Y)

                if (isRunning.get() && !isPaused.get()) {
                    val lx = applyStickDeadzone(rawLx)
                    val ly = applyStickDeadzone(rawLy)
                    val (rawRx, rawRy) = readRightStickAxes(event)
                    val rx = applyStickDeadzone(rawRx)
                    val ry = applyStickDeadzone(rawRy)

                    var axisBits = 0
                    if (lTrig >= 0.30f) axisBits = axisBits or RETRO_L2
                    if (rTrig >= 0.30f) axisBits = axisBits or RETRO_R2
                    if (hatX <= -0.5f) axisBits = axisBits or RETRO_LEFT
                    if (hatX >= 0.5f) axisBits = axisBits or RETRO_RIGHT
                    if (hatY <= -0.5f) axisBits = axisBits or RETRO_UP
                    if (hatY >= 0.5f) axisBits = axisBits or RETRO_DOWN

                    hardwareLeftStickX.set(lx.toInt())
                    hardwareLeftStickY.set(ly.toInt())
                    hardwareRightStickX.set(rx.toInt())
                    hardwareRightStickY.set(ry.toInt())
                    hardwareAxisMask.set(axisBits)
                    pushCombinedInputToNative()

                    if (kotlin.math.abs(lx.toInt()) > 3000 ||
                        kotlin.math.abs(ly.toInt()) > 3000 ||
                        kotlin.math.abs(rx.toInt()) > 3000 ||
                        kotlin.math.abs(ry.toInt()) > 3000 ||
                        axisBits != 0
                    ) {
                        notifyHardwareGamepadActive()
                    }
                    return true
                }

                // Modo UI (menu ou emulação pausada): direciona HAT/analógico esquerdo + L2/R2
                val direction: String? = when {
                    kotlin.math.abs(hatX) >= 0.55f || kotlin.math.abs(hatY) >= 0.55f -> {
                        if (kotlin.math.abs(hatX) >= kotlin.math.abs(hatY)) {
                            if (hatX < 0f) "dpadLeft" else "dpadRight"
                        } else {
                            if (hatY < 0f) "dpadUp" else "dpadDown"
                        }
                    }
                    kotlin.math.abs(rawLx) >= 0.60f || kotlin.math.abs(rawLy) >= 0.60f -> {
                        if (kotlin.math.abs(rawLx) >= kotlin.math.abs(rawLy)) {
                            if (rawLx < 0f) "dpadLeft" else "dpadRight"
                        } else {
                            if (rawLy < 0f) "dpadUp" else "dpadDown"
                        }
                    }
                    else -> null
                }

                val directionChanged = direction != currentUiDirection
                if (directionChanged) {
                    mainHandler.removeCallbacks(uiDirectionRepeatRunnable)
                    currentUiDirection = direction
                    if (direction != null) {
                        emitGamepadUiAction(direction)
                        notifyHardwareGamepadActive()
                        mainHandler.postDelayed(uiDirectionRepeatRunnable, UI_MOTION_REPEAT_MS)
                    }
                }

                val lPressed = if (uiLeftTriggerPressed) lTrig >= 0.40f else lTrig >= 0.55f
                val rPressed = if (uiRightTriggerPressed) rTrig >= 0.40f else rTrig >= 0.55f
                val triggerChanged = (lPressed != uiLeftTriggerPressed) || (rPressed != uiRightTriggerPressed)
                if (lPressed && !uiLeftTriggerPressed) {
                    emitGamepadUiAction("l2")
                    notifyHardwareGamepadActive()
                }
                if (rPressed && !uiRightTriggerPressed) {
                    emitGamepadUiAction("r2")
                    notifyHardwareGamepadActive()
                }
                uiLeftTriggerPressed = lPressed
                uiRightTriggerPressed = rPressed

                if (directionChanged ||
                    triggerChanged ||
                    direction != null ||
                    lPressed ||
                    rPressed ||
                    event.isFromSource(InputDevice.SOURCE_JOYSTICK)
                ) {
                    return true
                }
            }
        }
        return super.onGenericMotionEvent(event)
    }

    private fun mapGenericHidKeyToUiAction(keyCode: Int): String? {
        return when (keyCode) {
            KeyEvent.KEYCODE_BUTTON_1 -> "a"
            KeyEvent.KEYCODE_BUTTON_2 -> "b"
            KeyEvent.KEYCODE_BUTTON_3 -> "x"
            KeyEvent.KEYCODE_BUTTON_4 -> "y"
            KeyEvent.KEYCODE_BUTTON_5 -> "l1"
            KeyEvent.KEYCODE_BUTTON_6 -> "r1"
            KeyEvent.KEYCODE_BUTTON_7 -> "l2"
            KeyEvent.KEYCODE_BUTTON_8 -> "r2"
            KeyEvent.KEYCODE_BUTTON_9 -> "select"
            KeyEvent.KEYCODE_BUTTON_10 -> "start"
            KeyEvent.KEYCODE_BUTTON_11 -> "l3"
            KeyEvent.KEYCODE_BUTTON_12 -> "r3"
            KeyEvent.KEYCODE_BUTTON_13 -> "select"
            KeyEvent.KEYCODE_BUTTON_14 -> "start"
            KeyEvent.KEYCODE_BUTTON_15 -> "l2"
            KeyEvent.KEYCODE_BUTTON_16 -> "r2"
            else -> null
        }
    }

    private fun mapKeyCodeToRetroBit(keyCode: Int, event: KeyEvent? = null): Int {
        return when (keyCode) {
            KeyEvent.KEYCODE_BUTTON_A, KeyEvent.KEYCODE_BUTTON_1 -> RETRO_B
            KeyEvent.KEYCODE_BUTTON_B, KeyEvent.KEYCODE_BUTTON_2 -> RETRO_A
            KeyEvent.KEYCODE_BUTTON_X, KeyEvent.KEYCODE_BUTTON_3 -> RETRO_Y
            KeyEvent.KEYCODE_BUTTON_Y, KeyEvent.KEYCODE_BUTTON_4 -> RETRO_X
            KeyEvent.KEYCODE_BUTTON_L1, KeyEvent.KEYCODE_BUTTON_5 -> RETRO_L
            KeyEvent.KEYCODE_BUTTON_R1, KeyEvent.KEYCODE_BUTTON_6 -> RETRO_R
            KeyEvent.KEYCODE_BUTTON_L2, KeyEvent.KEYCODE_BUTTON_7, KeyEvent.KEYCODE_BUTTON_15 -> RETRO_L2
            KeyEvent.KEYCODE_BUTTON_R2, KeyEvent.KEYCODE_BUTTON_8, KeyEvent.KEYCODE_BUTTON_16 -> RETRO_R2
            KeyEvent.KEYCODE_BUTTON_SELECT, KeyEvent.KEYCODE_BUTTON_9, KeyEvent.KEYCODE_BUTTON_13 -> RETRO_SELECT
            KeyEvent.KEYCODE_BUTTON_START, KeyEvent.KEYCODE_BUTTON_10, KeyEvent.KEYCODE_BUTTON_14 -> RETRO_START
            KeyEvent.KEYCODE_BUTTON_THUMBL, KeyEvent.KEYCODE_BUTTON_11 -> RETRO_L3
            KeyEvent.KEYCODE_BUTTON_THUMBR, KeyEvent.KEYCODE_BUTTON_12 -> RETRO_R3
            KeyEvent.KEYCODE_DPAD_UP -> RETRO_UP
            KeyEvent.KEYCODE_DPAD_DOWN -> RETRO_DOWN
            KeyEvent.KEYCODE_DPAD_LEFT -> RETRO_LEFT
            KeyEvent.KEYCODE_DPAD_RIGHT -> RETRO_RIGHT
            KeyEvent.KEYCODE_MENU -> if (isDirectGamepadKeySource(event)) RETRO_START else 0
            KeyEvent.KEYCODE_MEDIA_RECORD -> if (isDirectGamepadKeySource(event)) RETRO_SELECT else 0
            KeyEvent.KEYCODE_BACK -> if (isDirectGamepadKeySource(event)) RETRO_SELECT else 0
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
        applyEdgeToEdgeAndCutout()
        isActivityResumed.set(true)
        lifecyclePaused.set(false)
        syncPauseAndServiceState()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            applyEdgeToEdgeAndCutout()
        }
    }

    override fun onPause() {
        isActivityResumed.set(false)
        lifecyclePaused.set(true)
        resetUiGamepadMotionState()
        cancelHardwareSelectFastForward()
        resetAllInputAtomics()
        pushCombinedInputToNative()
        if (isRunning.get()) {
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
        resetUiGamepadMotionState()
        cancelHardwareSelectFastForward()
        inputManager?.unregisterInputDeviceListener(inputDeviceListener)
        inputManager = null
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
    private external fun nativeUpdateInput(
        joypadMask: Int,
        leftX: Short,
        leftY: Short,
        rightX: Short,
        rightY: Short
    )
    private external fun nativeSaveState(path: String): Boolean
    private external fun nativeLoadState(path: String): Boolean
    private external fun nativeGetFrameWidth(): Int
    private external fun nativeGetFrameHeight(): Int
    private external fun nativeUnloadCore()
}
