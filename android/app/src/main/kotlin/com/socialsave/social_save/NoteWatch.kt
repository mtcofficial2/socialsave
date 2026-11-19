package com.socialsave.social_save

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Records the title and words on a notification after the owner says yes.
 * The system binds this only when that person allows notification access.
 */
class NoteWatch : NotificationListenerService() {
    override fun onListenerConnected() {
        watch = this
        readShown()
    }

    override fun onListenerDisconnected() {
        if (watch === this) watch = null
        super.onListenerDisconnected()
    }

    override fun onDestroy() {
        if (watch === this) watch = null
        super.onDestroy()
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        PhoneNotes.remember(this, sbn)
    }

    private fun readShown() {
        val shown = activeNotifications ?: return
        for (posted in shown) {
            PhoneNotes.remember(this, posted)
        }
    }

    companion object {
        @Volatile
        private var watch: NoteWatch? = null

        /** Reads notifications still on screen. False when the listener is not connected. */
        fun readShown(): Boolean {
            val service = watch ?: return false
            service.readShown()
            return true
        }
    }
}
