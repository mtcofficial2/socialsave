package com.socialsave.social_save

import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/** Quick Settings tile "SocialSave hotspot share": opens the app straight
 *  into Hotspot share (hotspot + QR, no file needed). */
class HotspotTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        qsTile?.let {
            it.state = Tile.STATE_INACTIVE
            it.label = "Hotspot share"
            it.updateTile()
        }
    }

    override fun onClick() {
        super.onClick()
        val intent = Intent(this, MainActivity::class.java).apply {
            putExtra(MainActivity.EXTRA_QUICK_ACTION, "hotspot_share")
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }
        if (Build.VERSION.SDK_INT >= 34) {
            val pi = PendingIntent.getActivity(
                this, 7, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            startActivityAndCollapse(pi)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
