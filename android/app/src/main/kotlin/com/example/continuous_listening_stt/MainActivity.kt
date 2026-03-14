package com.example.continuous_listening_stt

import android.media.AudioManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "stt_audio_channel"
    private var originalSystemVolume = 0

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "muteSystemSound" -> {
                        try {
                            originalSystemVolume = audioManager
                                .getStreamVolume(AudioManager.STREAM_SYSTEM)
                            audioManager.setStreamVolume(
                                AudioManager.STREAM_SYSTEM, 0, 0)
                            audioManager.adjustStreamVolume(
                                AudioManager.STREAM_SYSTEM,
                                AudioManager.ADJUST_MUTE, 0)
                        } catch (e: SecurityException) {
                            // Some OEMs restrict volume changes — safe to ignore,
                            // the beep may still play on this device
                        } catch (e: Exception) {
                            // Catch-all for any unexpected audio errors
                        }
                        result.success(null) // Always succeed so Dart doesn't throw
                    }
                    "unmuteSystemSound" -> {
                        try {
                            audioManager.adjustStreamVolume(
                                AudioManager.STREAM_SYSTEM,
                                AudioManager.ADJUST_UNMUTE, 0)
                            audioManager.setStreamVolume(
                                AudioManager.STREAM_SYSTEM,
                                originalSystemVolume, 0)
                        } catch (e: SecurityException) {
                            // Safe to ignore
                        } catch (e: Exception) {
                            // Safe to ignore
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }
}

// package com.example.continuous_listening_stt

// import io.flutter.embedding.android.FlutterActivity

// class MainActivity: FlutterActivity()
