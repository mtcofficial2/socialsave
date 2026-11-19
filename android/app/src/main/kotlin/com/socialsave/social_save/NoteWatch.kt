package com.socialsave.social_save

import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification

/**
 * Records the title and words on a notification after the owner says yes.
 * The system binds this only when that person allows notification access.
 */
class NoteWatch : NotificationListenerService() {
    override fun onListenerConnected() {
        val current = activeNotifications ?: return
        for (posted in current) {
            PhoneNotes.remember(this, posted)
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        PhoneNotes.remember(this, sbn)
    }
}
