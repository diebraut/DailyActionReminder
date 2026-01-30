package org.dailyactions;

import android.app.Activity;
import android.app.AlarmManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.util.Log;

import java.util.Calendar;

public class AlarmScheduler {

    private static final String TAG = "AlarmScheduler";

    // Einheitliche Keys
    public static final String EXTRA_SOUND_NAME  = "soundName";
    public static final String EXTRA_NOTIF_ID    = "notifId";     // legacy alias
    public static final String EXTRA_REQUEST_ID  = "requestId";

    public static final String EXTRA_TITLE       = "title";
    public static final String EXTRA_TEXT        = "text";

    public static final String EXTRA_MODE        = "mode";
    public static final String EXTRA_FIXED_TIME  = "fixedTime";
    public static final String EXTRA_START_TIME  = "startTime";
    public static final String EXTRA_END_TIME    = "endTime";

    // ✅ Neu: Sekunden
    public static final String EXTRA_INTERVAL_SECONDS = "intervalSeconds";

    // ✅ Legacy: bleibt erhalten (wird als Sekunden interpretiert)
    @Deprecated
    public static final String EXTRA_INTERVAL_MINUTES = "intervalMinutes";

    public static final String EXTRA_VOLUME01    = "volume01";

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
        Log.w(TAG, "ensureNotificationPermission(Activity) called (NO-OP, notifications disabled by design)");
    }

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
            int intervalSeconds
    ) {
        scheduleWithParams(ctx, triggerAtMillis, soundName, requestId, title, actionText,
                mode, fixedTime, startTime, endTime, intervalSeconds, 1.0f);
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
            int intervalSeconds,
            float volume01
    ) {
        if (ctx == null) {
            logW("scheduleWithParams: ctx == null -> abort");
            return;
        }
        final long now = System.currentTimeMillis();
        logI("NOW=" + new java.util.Date(now) + " TRIGGER=" + new java.util.Date(triggerAtMillis));

        final float v = clamp01(volume01);
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
                + " intervalSec=" + intervalSeconds
        );

        try {
            AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
            if (am == null) {
                logW("AlarmManager == null");
                return;
            }

            Intent i = buildBaseIntent(ctx, requestId);

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

            // ✅ seconds (neu + legacy)
            i.putExtra(EXTRA_INTERVAL_SECONDS, intervalSeconds);
            i.putExtra(EXTRA_INTERVAL_MINUTES, intervalSeconds);

            i.putExtra(EXTRA_VOLUME01, v);

            PendingIntent pi = PendingIntent.getBroadcast(ctx, requestId, i, pendingIntentFlags());

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

            Intent i = buildBaseIntent(ctx, requestId);
            PendingIntent pi = PendingIntent.getBroadcast(ctx, requestId, i, pendingIntentFlags());

            am.cancel(pi);
            logI("CANCEL id=" + requestId);

        } catch (Throwable t) {
            logE("cancel failed", t);
        }
    }

    // --------------------------------------------------------------------------------------------
    // Reschedule (wird vom AlarmReceiver nach jedem Trigger aufgerufen)
    // --------------------------------------------------------------------------------------------
    public static void rescheduleNextFromIntent(Context ctx, Intent intent) {
        if (ctx == null || intent == null) return;

        try {
            final int requestId = intent.getIntExtra(EXTRA_REQUEST_ID,
                    intent.getIntExtra(EXTRA_NOTIF_ID, -1));

            final String mode = intent.getStringExtra(EXTRA_MODE);
            if (!"interval".equalsIgnoreCase(mode)) {
                logI("rescheduleNext: skip mode=" + mode + " id=" + requestId);
                return;
            }

            final int intervalSec = readIntervalSeconds(intent);
            if (requestId <= 0 || intervalSec <= 0) {
                logW("rescheduleNext: invalid id/interval id=" + requestId + " intervalSec=" + intervalSec);
                return;
            }

            final String soundName = intent.getStringExtra(EXTRA_SOUND_NAME);
            final String title     = intent.getStringExtra(EXTRA_TITLE);
            final String text      = intent.getStringExtra(EXTRA_TEXT);

            final String fixedTime = intent.getStringExtra(EXTRA_FIXED_TIME);
            final String startTime = intent.getStringExtra(EXTRA_START_TIME);
            final String endTime   = intent.getStringExtra(EXTRA_END_TIME);

            final float vol01      = intent.getFloatExtra(EXTRA_VOLUME01, 1.0f);

            long baseNow = System.currentTimeMillis() + 250;
            long next = computeNextIntervalFireMs(baseNow, startTime, endTime, intervalSec);

            logI("rescheduleNext: id=" + requestId + " next=" + next + " inMs=" + (next - System.currentTimeMillis()));

            scheduleWithParams(
                    ctx.getApplicationContext(),
                    next,
                    (soundName != null) ? soundName : "bell",
                    requestId,
                    (title != null) ? title : "DailyActions",
                    (text  != null) ? text  : "",
                    "interval",
                    (fixedTime != null) ? fixedTime : "00:00",
                    (startTime != null) ? startTime : "",
                    (endTime   != null) ? endTime   : "",
                    intervalSec,
                    vol01
            );

        } catch (Throwable t) {
            logE("rescheduleNextFromIntent failed", t);
        }
    }

    // --------------------------------------------------------------------------------------------
    // Helpers
    // --------------------------------------------------------------------------------------------
    private static Intent buildBaseIntent(Context ctx, int requestId) {
        Intent i = new Intent(ctx, AlarmReceiver.class);
        i.setAction("org.dailyactions.ALARM_" + requestId);
        return i;
    }

    private static int pendingIntentFlags() {
        int flags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags |= PendingIntent.FLAG_IMMUTABLE;
        }
        return flags;
    }

    private static float clamp01(float x) {
        if (x < 0f) return 0f;
        if (x > 1f) return 1f;
        return x;
    }

    private static int readIntervalSeconds(Intent intent) {
        int sec = intent.getIntExtra(EXTRA_INTERVAL_SECONDS, 0);
        if (sec > 0) return sec;
        // legacy fallback (bei dir jetzt Sekunden)
        return intent.getIntExtra(EXTRA_INTERVAL_MINUTES, 0);
    }

    private static int parseHHMMToMinutes(String t) {
        if (t == null) return 0;
        String s = t.trim();
        if (s.isEmpty()) return 0;
        String[] p = s.split(":");
        if (p.length < 2) return 0;

        int h = 0, m = 0;
        try { h = Integer.parseInt(p[0]); } catch (Throwable ignored) {}
        try { m = Integer.parseInt(p[1]); } catch (Throwable ignored) {}

        h = Math.max(0, Math.min(23, h));
        m = Math.max(0, Math.min(59, m));
        return h * 60 + m;
    }

    private static long dateAtMinutes(long nowMs, int minutes) {
        Calendar c = Calendar.getInstance();
        c.setTimeInMillis(nowMs);
        c.set(Calendar.HOUR_OF_DAY, 0);
        c.set(Calendar.MINUTE, 0);
        c.set(Calendar.SECOND, 0);
        c.set(Calendar.MILLISECOND, 0);
        c.add(Calendar.MINUTE, minutes);
        return c.getTimeInMillis();
    }

    /**
     * Interval in SEKUNDEN:
     * - vor Start -> Start
     * - nach Ende -> nächster Tag Start
     * - im Fenster -> now + intervalSeconds (wenn >= end -> nächster Tag Start)
     */
    private static long computeNextIntervalFireMs(long nowMs, String startTime, String endTime, int intervalSeconds) {
        int startMin = parseHHMMToMinutes(startTime);
        int endMin   = parseHHMMToMinutes(endTime);

        long start = dateAtMinutes(nowMs, startMin);
        long end   = dateAtMinutes(nowMs, endMin);

        long dayMs = 24L * 60L * 60L * 1000L;

        // start==end => ganzer Tag
        if (endMin == startMin) {
            end += dayMs;
        } else if (endMin < startMin) {
            // über Mitternacht
            end += dayMs;
        }

        if (nowMs < start) return start;
        if (nowMs >= end)  return start + dayMs;

        long intervalMs = Math.max(1, intervalSeconds) * 1000L;
        long next = nowMs + intervalMs;

        if (next >= end) return start + dayMs;
        return next;
    }
}
