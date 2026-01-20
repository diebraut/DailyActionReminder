package org.dailyactions;

import android.app.Activity;
import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.util.Log;

public class AlarmScheduler {

    private static final String TAG = "AlarmScheduler";

    // Einheitliche Keys
    public static final String EXTRA_SOUND_NAME = "soundName";
    public static final String EXTRA_NOTIF_ID = "notifId";     // legacy alias
    public static final String EXTRA_REQUEST_ID = "requestId";

    public static final String EXTRA_TITLE = "title";
    public static final String EXTRA_TEXT = "text";

    public static final String EXTRA_MODE = "mode";
    public static final String EXTRA_FIXED_TIME = "fixedTime";
    public static final String EXTRA_START_TIME = "startTime";
    public static final String EXTRA_END_TIME = "endTime";
    public static final String EXTRA_INTERVAL_MINUTES = "intervalMinutes";
    public static final String EXTRA_VOLUME01 = "volume01";

    // --------------------------------------------------------------------------------------------
    // Debug helper
    // --------------------------------------------------------------------------------------------
    private static void logI(String msg) { Log.i(TAG, msg); }
    private static void logW(String msg) { Log.w(TAG, msg); }
    private static void logE(String msg, Throwable t) { Log.e(TAG, msg, t); }

    // ============================================================================================
    // WIRD VON Qt BEIM START AUFGERUFEN – DARF NICHT ENTFERNT WERDEN
    // ============================================================================================
    public static void ensureNotificationPermission(Activity activity) {
        // Design-Entscheidung: KEINE Notifications, KEINE Runtime-Notification-Permission
        Log.w(TAG, "ensureNotificationPermission(Activity) called (NO-OP, notifications disabled by design)");
    }

    // Optional: falls irgendwo intern Context-Version aufgerufen wird
    @SuppressWarnings("unused")
    public static void ensureNotificationPermission(Context ctx) {
        Log.w(TAG, "ensureNotificationPermission(Context) called (NO-OP, notifications disabled by design)");
    }

    // --------------------------------------------------------------------------------------------
    // Public API (ohne Volume)
    // --------------------------------------------------------------------------------------------
    public static void scheduleWithParams(
            Context ctx,
            long triggerAtMillis,
            String soundName,
            int requestId,
            String title,
            String actionText,
            String mode,
            String fixedTime,
            String startTime,
            String endTime,
            int intervalMinutes
    ) {
        scheduleWithParams(ctx, triggerAtMillis, soundName, requestId, title, actionText,
                mode, fixedTime, startTime, endTime, intervalMinutes, 1.0f);
    }

    // --------------------------------------------------------------------------------------------
    // Public API (mit Volume)
    // --------------------------------------------------------------------------------------------
    public static void scheduleWithParams(
            Context ctx,
            long triggerAtMillis,
            String soundName,
            int requestId,
            String title,
            String actionText,
            String mode,
            String fixedTime,
            String startTime,
            String endTime,
            int intervalMinutes,
            float volume01
    ) {
        Log.e(TAG, "### scheduleWithParams CALLED ### requestId=" + requestId);

        if (ctx == null) {
            logW("scheduleWithParams: ctx == null -> abort");
            return;
        }

        final float v = clamp01(volume01);
        final long now = System.currentTimeMillis();
        final long inMs = triggerAtMillis - now;

        logI("SCHEDULE id=" + requestId
                + " at=" + triggerAtMillis
                + " inMs=" + inMs
                + " mode=" + mode
                + " sound=" + soundName
                + " vol=" + v
                + " fixed=" + fixedTime
                + " start=" + startTime
                + " end=" + endTime
                + " intervalMin=" + intervalMinutes
        );

        try {
            AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
            if (am == null) {
                logW("AlarmManager == null");
                return;
            }

            Intent i = new Intent(ctx, AlarmReceiver.class);
            i.setAction("org.dailyactions.ALARM_" + requestId);

            // Extras
            i.putExtra(EXTRA_SOUND_NAME, soundName);
            i.putExtra(EXTRA_NOTIF_ID, requestId);     // legacy
            i.putExtra(EXTRA_REQUEST_ID, requestId);

            i.putExtra(EXTRA_TITLE, title);
            i.putExtra(EXTRA_TEXT, actionText);

            i.putExtra(EXTRA_MODE, mode);
            i.putExtra(EXTRA_FIXED_TIME, fixedTime);
            i.putExtra(EXTRA_START_TIME, startTime);
            i.putExtra(EXTRA_END_TIME, endTime);
            i.putExtra(EXTRA_INTERVAL_MINUTES, intervalMinutes);

            i.putExtra(EXTRA_VOLUME01, v);

            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                flags |= PendingIntent.FLAG_IMMUTABLE;
            }

            PendingIntent pi = PendingIntent.getBroadcast(ctx, requestId, i, flags);

            // Wichtig: setExactAndAllowWhileIdle ab M (23), sonst setExact
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAtMillis, pi);
                logI("Alarm setExactAndAllowWhileIdle(RTC_WAKEUP) scheduled.");
            } else {
                am.setExact(AlarmManager.RTC_WAKEUP, triggerAtMillis, pi);
                logI("Alarm setExact(RTC_WAKEUP) scheduled.");
            }

        } catch (Throwable t) {
            logE("scheduleWithParams failed", t);
        }
    }

    public static void cancel(Context ctx, int requestId) {
        if (ctx == null) return;

        try {
            AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
            if (am == null) return;

            Intent i = new Intent(ctx, AlarmReceiver.class);
            i.setAction("org.dailyactions.ALARM_" + requestId);

            int flags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                flags |= PendingIntent.FLAG_IMMUTABLE;
            }

            PendingIntent pi = PendingIntent.getBroadcast(ctx, requestId, i, flags);
            am.cancel(pi);

            logI("CANCEL id=" + requestId);

        } catch (Throwable t) {
            logE("cancel failed", t);
        }
    }

    private static float clamp01(float x) {
        if (x < 0f) return 0f;
        if (x > 1f) return 1f;
        return x;
    }
}
