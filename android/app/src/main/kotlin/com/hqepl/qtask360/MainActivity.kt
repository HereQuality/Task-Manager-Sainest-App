package com.hqepl.qtask360

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "com.hqepl.qtask360/document_picker"
        private const val REQUEST_PICK_DOCUMENT = 4711
        private const val PREFS = "qtask360_pending_pick"
        private const val KEY_PATH = "pending_document_path"
        private const val KEY_NAME = "pending_document_name"
    }

    // Document picking is handled natively rather than through a Flutter
    // plugin, because of a failure mode confirmed on a real device (Vivo,
    // Android 15) via logcat: while the system document picker is in the
    // foreground, Android destroys and recreates THIS ACTIVITY without
    // killing the app's process at all (the background watcher isolate
    // kept ticking uninterrupted across the whole incident, same PID, while
    // a second FlutterEngine was spun up). That wipes every bit of Dart
    // state, including whatever `await`ed the picker's result -- so a
    // plugin-based pick silently produced nothing, every time, and looked
    // to the person like the app had restarted and lost their file.
    //
    // Android itself guarantees that a pending activity result is still
    // delivered to the RECREATED activity instance, so onActivityResult
    // below is reached even in that case. Persisting the picked file from
    // there (native side, synchronous commit) means the result outlives the
    // Dart VM's state entirely; Dart then claims it via
    // "consumePendingDocument" whenever it comes back up. See
    // lib/core/pending_attachment_service.dart for the other half.
    //
    // "Take photo" is NOT handled this way (tried once, reverted -- see
    // task_attachments_section.dart's own doc comment on why): the same
    // native-handoff pattern was applied to the camera too, but its
    // success/failure both had to be reported through
    // recoverPendingUpload() in pending_attachment_service.dart, which only
    // runs from an app-resume/auth-transition trigger in main.dart. On at
    // least one Android phone that trigger never fired reliably after
    // returning from the camera, so neither an upload nor an error ever
    // appeared. image_picker's own pickImage(source: camera) doesn't share
    // that weak link -- its Future resolves directly from onActivityResult
    // with no lifecycle signal in between -- so it's the camera path again,
    // with image_picker's own retrieveLostData() covering the rarer
    // Activity-teardown case instead of a bespoke native flow.
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickDocument" -> {
                        try {
                            val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                            }
                            startActivityForResult(intent, REQUEST_PICK_DOCUMENT)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    // Returns {path, name} for a document picked since the
                    // last call, or null. Clearing on read is deliberate:
                    // the same pick must never be uploaded twice if Dart
                    // asks again (startup AND resume both poll this).
                    "consumePendingDocument" -> {
                        val prefs = getSharedPreferences(PREFS, MODE_PRIVATE)
                        val path = prefs.getString(KEY_PATH, null)
                        val name = prefs.getString(KEY_NAME, null)
                        if (path == null) {
                            result.success(null)
                        } else {
                            prefs.edit().remove(KEY_PATH).remove(KEY_NAME).commit()
                            result.success(mapOf("path" to path, "name" to name))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_PICK_DOCUMENT || resultCode != Activity.RESULT_OK) return
        val uri: Uri = data?.data ?: return
        try {
            val name = queryDisplayName(uri) ?: "document"
            // Copied into this app's own cache immediately: the content://
            // URI's read permission is scoped to this activity instance and
            // does NOT survive the recreation described above, so holding
            // the URI alone would leave an unreadable handle. Done
            // synchronously so the copy is finished before the activity can
            // be torn down; task attachments are capped at 10MB server-side
            // (uploadTaskAttachment in upload.middleware.js), small enough
            // that this stays well clear of an ANR.
            val safeName = name.replace(Regex("[^A-Za-z0-9._-]"), "_")
            val out = File(cacheDir, "pick-${System.currentTimeMillis()}-$safeName")
            contentResolver.openInputStream(uri)?.use { input ->
                out.outputStream().use { output -> input.copyTo(output) }
            }
            // commit(), not apply(): apply()'s disk write is asynchronous,
            // and the whole point here is surviving an imminent teardown.
            getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                .putString(KEY_PATH, out.absolutePath)
                .putString(KEY_NAME, name)
                .commit()
        } catch (e: Exception) {
            // Nothing useful to surface from here -- Dart shows its own
            // message when no pending document turns up.
        }
    }

    private fun queryDisplayName(uri: Uri): String? {
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            ?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val idx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    if (idx >= 0) return cursor.getString(idx)
                }
            }
        return null
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // AndroidManifest.xml's android:showWhenLocked/android:turnScreenOn
        // cover the common case, but several OEM skins don't reliably honor
        // manifest-only flags when this Activity is cold-started fresh by a
        // full-screen-intent notification after its process was killed by
        // the OS's own background-app management. Setting them again here
        // via the actual runtime API -- what most alarm/call-style apps
        // rely on -- is more consistently honored across OEMs than the
        // manifest attributes alone.
        //
        // Deliberately NOT calling KeyguardManager.requestDismissKeyguard()
        // here -- on a device with a secure lock method (PIN/pattern/
        // biometric), that actively asks the OS to unlock the keyguard,
        // which makes Android show its own system PIN/biometric prompt
        // FIRST and only hands control to this Activity after the person
        // authenticates. setShowWhenLocked alone is what draws this
        // Activity directly on top of the (still-locked) keyguard with no
        // authentication required -- the same mechanism an incoming phone
        // call or a real alarm clock app uses to ring over the lock screen
        // without needing to be unlocked first.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        }
    }
}
