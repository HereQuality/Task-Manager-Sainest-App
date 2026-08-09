package com.hqepl.qtask360

import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

class MainActivity : FlutterActivity() {
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
