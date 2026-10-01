package com.example.glass_plugin

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

// Declared in the plugin's own AndroidManifest.xml, the way a plugin that
// re-arms alarms after a reboot declares its receiver: the app's manifest
// gets it only by merging the library's.
class GlassBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {}
}
