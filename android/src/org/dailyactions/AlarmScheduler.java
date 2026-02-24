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

    public static final String EXTRA_TRIGGER_AT_MILLIS = "triggerAtMillis";

    // ✅ Legacy: bleibt erhalten (wird als Sekunden interpretiert)
    @Deprecated
    public static final String EXTRA_INTERVAL_MINUTES = "intervalMinutes";

    public static final String EXTRA_VOLUME01    = "volume01";
    public static final String EXTRA_DURATION_SOUND    = "duration_sound";

    // --------------------------------------------------------------------------------------------
    // Debug helper
    // --------------------------------------------------------------------------------------------
    private static void logI(String msg) { Log.i(TAG, msg); }
    private static void logW(String msg) { Log.w(TAG, msg); }
    private static void logE(String msg, Throwable t) { Log.e(TAG, msg, t); }

    private static final String PREFS_NAME = "dailyactions_prefs";
    private static String keyNextAt(int id) { return "nextAtMs_" + id; }

    private static final String SP = "dailyactions_alarm";
    private static String keyPhase(int id) { return "phase_" + id; }

    private static void savePhaseMs(Context ctx, int id, long phaseMs) {
        ctx.getSharedPreferences(SP, 0).edit().putLong(keyPhase(id), phaseMs).apply();
    }

    private static long loadPhaseMs(Context ctx, int id) {
        return ctx.getSharedPreferences(SP, 0).getLong(keyPhase(id), 0L);
    }

    private static void saveNextAtMs(Context ctx, int requestId, long nextAtMs) {
        try {
            ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .edit()
                    .putLong(keyNextAt(requestId), nextAtMs)
                    .apply();
        } catch (Throwable t) {
            logE("saveNextAtMs failed", t);
        }
    }

    private static void clearNextAtMs(Context ctx, int requestId) {
        try {
            ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .edit()
                    .remove(keyNextAt(requestId))
                    .apply();
        } catch (Throwable t) {
            logE("clearNextAtMs failed", t);
        }
    }

    // QML/C++ liest das beim Startup
    public static long getNextAtMs(Context ctx, int requestId) {
        if (ctx == null || requestId <= 0) return 0L;
        try {
            return ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                    .getLong(keyNextAt(requestId), 0L);
        } catch (Throwable t) {
            logE("getNextAtMs failed", t);
            return 0L;
        }
    }

    // ============================================================================================
    // WIRD VON Qt BEIM START AUFGERUFEN – DARF NICHT ENTFERNT WERDEN
    // ============================================================================================
    public static void ensureNotificationPermission(Activity activity) {
        Log.w(TAG, "ensureNotificationPermission(Activity) called (NO-OP, notifications disabled by design)");
    }

    // --------------------------------------------------------------------------------------------
    // Check if a requestId is currently scheduled (PendingIntent exists)
    // --------------------------------------------------------------------------------------------
    public static boolean isScheduled(Context ctx, int requestId) {
        if (ctx == null) {
            logI("isScheduled? ctx =null");
            return false;
        }
        try {
            Intent i = buildBaseIntent(ctx, requestId);

            int flags = PendingIntent.FLAG_NO_CREATE;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                flags |= PendingIntent.FLAG_IMMUTABLE;
            }

            PendingIntent pi = PendingIntent.getBroadcast(ctx, requestId, i, flags);
            boolean ok = (pi != null);

            logI("isScheduled? id=" + requestId
                    + " action=" + i.getAction()
                    + " flags=" + flags
                    + " pi=" + ok
                    + (ok ? (" creatorPkg=" + pi.getCreatorPackage()) : "")
            );
            return ok;
        } catch (Throwable t) {
            logE("isScheduled failed", t);
            return false;
        }
    }


    @SuppressWarnings("unused")
    public static void ensureNotificationPermission(Context ctx) {
        Log.w(TAG, "ensureNotificationPermission(Context) called (NO-OP, notifications disabled by design)");
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
            float volume01,
            int   durationSound
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
                + " intervalSec=" + intervalSeconds
                + " durationSound=" + durationSound
                + " inMs=" + inMs
                + " mode=" + mode
                + " sound=" + soundName
                + " vol=" + v
                + " fixed=" + fixedTime
                + " start=" + startTime
                + " end=" + endTime
        );

        if ("interval".equalsIgnoreCase(mode)) {
            long phase = loadPhaseMs(ctx, requestId);
            if (phase <= 0L) savePhaseMs(ctx, requestId, triggerAtMillis);
        }

        try {
            AlarmManager am = (AlarmManager) ctx.getSystemService(Context.ALARM_SERVICE);
            if (am == null) {
                logW("AlarmManager == null");
                return;
            }

            // Optional aber sinnvoll ab Android 12+: vorher prüfen, sonst ggf. SecurityException
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                if (!am.canScheduleExactAlarms()) {
                    logW("No permission to schedule exact alarms (canScheduleExactAlarms=false)");
                    // -> hier ggf. graceful fallback oder Settings-Intent ACTION_REQUEST_SCHEDULE_EXACT_ALARM
                    return;
                }
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

            i.putExtra(EXTRA_INTERVAL_SECONDS, intervalSeconds);
            i.putExtra(EXTRA_VOLUME01, v);

            i.putExtra(EXTRA_VOLUME01, v);
            i.putExtra(EXTRA_DURATION_SOUND, durationSound);

            i.putExtra(EXTRA_TRIGGER_AT_MILLIS, triggerAtMillis);

            PendingIntent pi = PendingIntent.getBroadcast(ctx, requestId, i, pendingIntentFlags());

            // "Show intent" für AlarmClock UI (wenn User auf Alarm tippt).
            // Minimal: öffnet deine App/QtActivity.
            Intent show = new Intent(ctx, org.qtproject.qt.android.bindings.QtActivity.class);
            show.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);

            int showFlags = PendingIntent.FLAG_UPDATE_CURRENT;
            if (Build.VERSION.SDK_INT >= 23) showFlags |= PendingIntent.FLAG_IMMUTABLE;

            PendingIntent showPi = PendingIntent.getActivity(ctx, requestId, show, showFlags);

            AlarmManager.AlarmClockInfo ac =
                    new AlarmManager.AlarmClockInfo(triggerAtMillis, showPi);

            am.setAlarmClock(ac, pi);
            logI("Alarm setAlarmClock() scheduled.");

            saveNextAtMs(ctx.getApplicationContext(), requestId, triggerAtMillis);

        } catch (SecurityException se) {
            logE("scheduleWithParams failed: missing exact alarm permission", se);
        } catch (Throwable t) {
            logE("scheduleWithParams failed", t);
        }
    }

    private static void clearPhase(Context ctx, int id) {
        ctx.getSharedPreferences(SP, 0).edit().remove(keyPhase(id)).apply();
    }

    public static void cancel(Context ctx, int requestId) {
        if (ctx == null) return;
        Context app = ctx.getApplicationContext();

        AlarmManager am = (AlarmManager) app.getSystemService(Context.ALARM_SERVICE);
        if (am == null) return;

        Intent i = new Intent(app, AlarmReceiver.class);
        i.setAction("org.dailyactions.ALARM_" + requestId); // MUSS exakt zum Schedule-Intent passen

        int flags = PendingIntent.FLAG_NO_CREATE;
        if (Build.VERSION.SDK_INT >= 23) flags |= PendingIntent.FLAG_IMMUTABLE;

        PendingIntent pi = PendingIntent.getBroadcast(app, requestId, i, flags);
        logI("CANCEL id=" + requestId + " pi=" + (pi != null));

        if (pi != null) {
            am.cancel(pi);
            pi.cancel();
        }

        clearNextAtMs(app, requestId);
        clearPhase(app, requestId);
    }

    public static void cancelAll(Context ctx, int[] ids) {
        if (ctx == null) return;
        Context app = ctx.getApplicationContext();

        if (ids == null || ids.length == 0) {
            logI("CANCEL_ALL count=0");
            return;
        }

        int count = 0;

        for (int id : ids) {
            if (id <= 0) continue;

            try {
                cancel(app, id);
                count++;
            } catch (Throwable ignored) {}
        }

        logI("CANCEL_ALL count=" + count);
    }

    public static void rescheduleNextFromIntent(Context ctx, Intent intent) {
        if (ctx == null || intent == null) return;

        try {
            final Context appCtx = ctx.getApplicationContext();

            final int requestId = intent.getIntExtra(EXTRA_REQUEST_ID,
                    intent.getIntExtra(EXTRA_NOTIF_ID, -1));

            Log.w(TAG, "RESCHEDULE done id=" + requestId);

            final String mode = intent.getStringExtra(EXTRA_MODE);
            if (!"interval".equalsIgnoreCase(mode)) return;

            final int intervalSec = readIntervalSeconds(intent);
            if (requestId <= 0 || intervalSec <= 0) return;

            final String soundName = intent.getStringExtra(EXTRA_SOUND_NAME);
            final String title     = intent.getStringExtra(EXTRA_TITLE);
            final String text      = intent.getStringExtra(EXTRA_TEXT);

            final String fixedTime = intent.getStringExtra(EXTRA_FIXED_TIME);
            final String startTime = intent.getStringExtra(EXTRA_START_TIME);
            final String endTime   = intent.getStringExtra(EXTRA_END_TIME);

            final float vol01 = intent.getFloatExtra(EXTRA_VOLUME01, 1.0f);
            final int durationSound = intent.getIntExtra(EXTRA_DURATION_SOUND, 1);

            final long intervalMs = intervalSec * 1000L;

            // 🔴 DAS IST DER WICHTIGSTE FIX
            final long lastPlannedTrigger =
                    intent.getLongExtra(EXTRA_TRIGGER_AT_MILLIS, -1L);

            if (lastPlannedTrigger <= 0) {
                logW("rescheduleNext: missing EXTRA_TRIGGER_AT_MILLIS -> fallback abort id=" + requestId);
                return;
            }

            // ✅ Phase-stabil: nächster Tick = letzter geplanter Tick + Intervall
            final long next = lastPlannedTrigger + intervalMs;

            logI("rescheduleNext: id=" + requestId
                    + " lastPlanned=" + lastPlannedTrigger
                    + " next=" + next
                    + " delta=" + intervalMs
            );

            scheduleWithParams(
                    appCtx,
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
                    vol01,
                    durationSound
            );

            saveNextAtMs(appCtx, requestId, next);

        } catch (Throwable t) {
            logE("rescheduleNextFromIntent failed", t);
        }
    }

    private static long computeNextFromPhase(long now, long phase, long stepMs) {
        if (stepMs <= 0) return now;
        if (now <= phase) return phase;
        long k = (now - phase + stepMs - 1) / stepMs; // ceil
        return phase + k * stepMs;
    }

    private static boolean isWithinWindow(long tMs, int startMin, int endMin) {
        if (startMin < 0 && endMin < 0) return true;

        java.util.Calendar c = java.util.Calendar.getInstance();
        c.setTimeInMillis(tMs);
        int curMin = c.get(java.util.Calendar.HOUR_OF_DAY) * 60 + c.get(java.util.Calendar.MINUTE);

        if (startMin >= 0 && endMin >= 0) {
            if (startMin == endMin) return true; // "ganztägig" Interpretation
            if (startMin < endMin) {
                return curMin >= startMin && curMin < endMin;
            } else {
                // über Mitternacht (z.B. 22:00-06:00)
                return (curMin >= startMin) || (curMin < endMin);
            }
        } else if (startMin >= 0) {
            return curMin >= startMin;
        } else { // endMin >= 0
            return curMin < endMin;
        }
    }

    private static int parseHHMMToMinutes(String s) {
        try {
            if (s == null) return -1;
            s = s.trim();
            if (s.isEmpty() || !s.contains(":")) return -1;
            String[] p = s.split(":");
            if (p.length < 2) return -1;
            int hh = Integer.parseInt(p[0]);
            int mm = Integer.parseInt(p[1]);
            if (hh < 0 || hh > 23 || mm < 0 || mm > 59) return -1;
            return hh * 60 + mm;
        } catch (Throwable t) {
            return -1;
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
     static long computeNextIntervalFireMs(long nowMs, String startTime, String endTime, int intervalSeconds) {
         final int startMin = parseHHMMToMinutes(startTime);
         final int endMin   = parseHHMMToMinutes(endTime);

         final long dayMs = 24L * 60L * 60L * 1000L;

         long start = dateAtMinutes(nowMs, startMin);
         long end   = dateAtMinutes(nowMs, endMin);

         // start==end => ganzer Tag
         if (endMin == startMin) {
             end += dayMs;
         } else if (endMin < startMin) {
             // über Mitternacht
             end += dayMs;
         }

         // außerhalb Fenster
         if (nowMs < start) return start;
         if (nowMs >= end)  return start + dayMs;

         final long intervalMs = Math.max(1, intervalSeconds) * 1000L;

         // ✅ auf Tick ausrichten: nächster Tick ab "start"
         long elapsed = nowMs - start;
         long k = elapsed / intervalMs;              // aktueller Tick-Index
         long next = start + (k + 1) * intervalMs;   // nächster Tick

         if (next >= end) return start + dayMs;
         return next;
     }
}
