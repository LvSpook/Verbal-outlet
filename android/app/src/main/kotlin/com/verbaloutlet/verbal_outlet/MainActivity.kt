package com.verbaloutlet.verbal_outlet

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.speech.tts.TextToSpeech
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale

class MainActivity : FlutterActivity() {
    private var tts: TextToSpeech? = null
    private var ready = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Reading AI questions aloud, using the phone's own speech engine.
        tts = TextToSpeech(this) { status ->
            ready = status == TextToSpeech.SUCCESS
            if (ready) {
                tts?.language = Locale.getDefault()
            }
        }

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "verbal_outlet/speech",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "speak" -> {
                    val text = call.argument<String>("text").orEmpty()
                    if (text.isBlank() || tts == null || !ready) {
                        // Not an error: the question is still on screen.
                        result.success(false)
                    } else {
                        val spoken = tts?.speak(
                            text,
                            TextToSpeech.QUEUE_FLUSH,
                            null,
                            "verbal_outlet_question",
                        )
                        result.success(spoken == TextToSpeech.SUCCESS)
                    }
                }
                "stop" -> {
                    tts?.stop()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // Installing an update: the APK is downloaded by Dart, this opens the
        // system installer for it. Android always asks for a tap, so this is a
        // hand-off rather than a silent replace.
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "verbal_outlet/update",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "installApk" -> {
                    val path = call.argument<String>("path").orEmpty()
                    if (path.isBlank()) {
                        result.success(false)
                        return@setMethodCallHandler
                    }

                    // Android 8+ requires the user to permit installs from this
                    // app first; without this, the installer intent fails
                    // silently and the update looks broken.
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                        !packageManager.canRequestPackageInstalls()
                    ) {
                        startActivity(
                            Intent(
                                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                                Uri.parse("package:$packageName"),
                            ),
                        )
                        result.success(false)
                        return@setMethodCallHandler
                    }

                    try {
                        val file = File(path)
                        val uri: Uri = FileProvider.getUriForFile(
                            this,
                            "$packageName.updates",
                            file,
                        )
                        val intent = Intent(Intent.ACTION_VIEW).apply {
                            setDataAndType(uri, "application/vnd.android.package-archive")
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        }
                        startActivity(intent)
                        result.success(true)
                    } catch (error: Exception) {
                        result.success(false)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        tts?.stop()
        tts?.shutdown()
        tts = null
        super.onDestroy()
    }
}
