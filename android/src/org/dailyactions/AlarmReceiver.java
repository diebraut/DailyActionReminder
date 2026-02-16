package org.dailyactions;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.res.AssetFileDescriptor;
import android.media.AudioAttributes;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;
import android.util.Log;

import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;

import org.json.JSONObject;

import org.json.JSONObject;

/**
 * AlarmReceiver
 * - Receives AlarmManager triggers (interval / fixed time)
 * - Shows a silent notification (channel is silent)
 * - Reschedules interval alarms via AlarmScheduler
 * - Plays a short beep immediately (NO internal queue)
 *
 * IMPORTANT:
 * If you want strictly sequential playback for multiple actions, de-conflict/stagger at scheduling time.
 */

public class AlarmReceiver extends BroadcastReceiver {

    private static final String TAG = "AlarmReceiver";

    // Notification
    // IMPORTANT:
    // - Android NotificationChannel settings are sticky once created.
    // - We bump the channel id so existing installs immediately get a SILENT channel.
    private static final String CH_ID   = "dailyactions_reminder_silent_v2";
    private static final String CH_NAME = "DailyActionReminder";
    private static final String CH_DESC = "Aktionen/Erinnerungen";

    // Hard stop so the beep stays short
    private static final int BEEP_MAX_MS = 1000; // 1.2s
    private static final int WAKELOCK_MS = 10; // keep CPU awake briefly

    // -------------------- SEQUENTIAL PLAYBACK QUEUE --------------------
    private static final Object PLAY_LOCK = new Object();
    private static final java.util.ArrayDeque<ExpectedActions.Action> PLAY_Q = new java.util.ArrayDeque<>();
    private static boolean PLAYING = false;


    // --------------------------------------------------------------------------------------------
    // Expected / planned actions registry
    // - Holds all information needed to execute an action in onReceive() without relying on Intent extras.
    // - Populated by the scheduling side (e.g. AlarmScheduler / JNI bridge) via addPlannedAktions().
    // --------------------------------------------------------------------------------------------
    private static final ExpectedActions EXPECTED_ACTIONS = new ExpectedActions();

    /**
     * Register / update a planned action.
     * Keep ALL fields that onReceive() may need (sound/volume + notification + scheduling parameters).
     */
    public static void addPlannedAktions(
            Context ctx,
            int requestId,
            long triggerAtMillis,
            String soundName,
            float volume01,
            String title,
            String actionText,
            String mode,
            String fixedTime,
            String startTime,
            String endTime,
            int intervalSeconds
    ) {
        if (ctx == null) {
            Log.w(TAG, "ExpectedActions: add/update aborted (ctx==null) id=" + requestId);
            return;
        }
        EXPECTED_ACTIONS.put(ctx.getApplicationContext(), new ExpectedActions.Action(
                requestId,
                triggerAtMillis,
                soundName,
                clamp01(volume01),
                title,
                actionText,
                mode,
                fixedTime,
                startTime,
                endTime,
                intervalSeconds
        ));
        Log.w(TAG, "ExpectedActions: add/update id=" + requestId + " trig=" + triggerAtMillis
                + " mode=" + mode + " sound=" + soundName + " vol=" + clamp01(volume01));
    }

    /**
     * Backwards-compatible overload (in-memory only).
     * NOTE: This will NOT survive process death. Prefer the Context overload above.
     */
    public static void addPlannedAktions(
            int requestId,
            long triggerAtMillis,
            String soundName,
            float volume01,
            String title,
            String actionText,
            String mode,
            String fixedTime,
            String startTime,
            String endTime,
            int intervalSeconds
    ) {
        EXPECTED_ACTIONS.putInMemoryOnly(new ExpectedActions.Action(
                requestId,
                triggerAtMillis,
                soundName,
                clamp01(volume01),
                title,
                actionText,
                mode,
                fixedTime,
                startTime,
                endTime,
                intervalSeconds
        ));
        Log.w(TAG, "ExpectedActions: add/update (memory-only) id=" + requestId + " trig=" + triggerAtMillis);
    }

    /**
     * Remove a planned action (e.g. after cancel()).
     */
    public static void removeAktions(Context ctx, int requestId) {
        if (ctx == null) {
            Log.w(TAG, "ExpectedActions: remove aborted (ctx==null) id=" + requestId);
            return;
        }
        EXPECTED_ACTIONS.remove(ctx.getApplicationContext(), requestId);
        Log.w(TAG, "ExpectedActions: remove id=" + requestId);
    }

    /** Backwards-compatible overload (memory-only). */
    public static void removeAktions(int requestId) {
        EXPECTED_ACTIONS.removeInMemoryOnly(requestId);
        Log.w(TAG, "ExpectedActions: remove (memory-only) id=" + requestId);
    }

    public static void clearAllExpectedActions(Context ctx) {
        if (ctx == null) return;
        EXPECTED_ACTIONS.clearAll(ctx.getApplicationContext());
    }

    /**
     * Optional helper: fetch a planned action snapshot (can be null).
     */
    private static ExpectedActions.Action getExpectedAction(Context ctx, int requestId) {
        return EXPECTED_ACTIONS.get(ctx, requestId);
    }

    /**
     * Internal registry for planned actions.
     */

    // Callback used by ExpectedActions to execute an action (play + reschedule etc.)
    private interface ActionRunner {
        void run(ExpectedActions.Action a, boolean executeFull);
    }

    private static final class ExpectedActions {

        private static final String PREFS_NAME = "dailyactions_expected_actions";
        private static final String KEY_PREFIX = "a_";

        private static final String KEY_HANDLED_PREFIX = "h_";
        private final java.util.HashMap<Integer, Action> map = new java.util.HashMap<>();

        private SharedPreferences prefs(Context ctx) {
            return ctx.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE);
        }

        private String key(int requestId) {
            return KEY_PREFIX + requestId;
        }

        private String handledKey(int requestId) {
            return KEY_HANDLED_PREFIX + requestId;
        }

        private long getHandledTriggerMs(Context ctx, int requestId) {
            try {
                return prefs(ctx).getLong(handledKey(requestId), -1L);
            } catch (Throwable t) {
                return -1L;
            }
        }

        private java.util.List<Action> getAll(Context ctx) {
            java.util.ArrayList<Action> out = new java.util.ArrayList<>();
            java.util.Map<String, ?> all = prefs(ctx).getAll();
            for (java.util.Map.Entry<String, ?> e : all.entrySet()) {
                String k = e.getKey();
                if (k == null || !k.startsWith(KEY_PREFIX)) continue;
                Object v = e.getValue();
                if (!(v instanceof String)) continue;
                Action a = Action.fromJson((String) v);
                if (a != null) out.add(a);
            }
            return out;
        }

        private void markHandledTriggerMs(Context ctx, int requestId, long triggerAtMillis) {
            try {
                prefs(ctx).edit().putLong(handledKey(requestId), triggerAtMillis).apply();
            } catch (Throwable t) {
                Log.w(TAG, "ExpectedActions: markHandled failed id=" + requestId + ": " + t);
            }
        }


        private synchronized void put(Context ctx, Action a) {
            a.isExecuted = false;        // NEU: beim (re)Schedule reset
            map.put(a.requestId, a);
            persistLocked(ctx, a);
        }

        private synchronized void putInMemoryOnly(Action a) {
            a.isExecuted = false;        // NEU: beim (re)Schedule reset
            map.put(a.requestId, a);
        }

        private synchronized void remove(Context ctx, int requestId) {
            map.remove(requestId);
            prefs(ctx).edit()
                    .remove(key(requestId))          // a_<id>
                    .remove(handledKey(requestId))   // h_<id>  <-- WICHTIG
                    .apply();
        }

        private synchronized void removeInMemoryOnly(int requestId) {
            map.remove(requestId);
        }

        private synchronized void clearAll(Context ctx) {
            map.clear();
            prefs(ctx).edit().clear().apply();
        }

        private synchronized void setExecuted(Context ctx, int requestId, boolean executed) {
            Action cur = get(ctx, requestId);
            if (cur == null) return;

            Action upd = cur.withExecuted(executed);

            // cache aktualisieren
            map.put(requestId, upd);

            // persistieren
            persistLocked(ctx, upd);
        }

        private synchronized Action get(Context ctx, int requestId) {
            Action a = map.get(requestId);
            if (a != null) return a.copy();

            // fallback to prefs
            try {
                String json = prefs(ctx).getString(key(requestId), null);
                if (json == null) return null;
                Action parsed = Action.fromJson(json);
                if (parsed != null) {
                    map.put(requestId, parsed);
                    return parsed.copy();
                }
            } catch (Throwable t) {
                Log.w(TAG, "ExpectedActions: get() parse failed id=" + requestId + ": " + t);
            }
            return null;
        }
        // Debug: dump all persisted expected actions (sorted by trigger time)
        void logAllExpectedActions(Context ctx, long nowMs) {
            if (ctx == null) return;
            try {
                java.util.ArrayList<Action> list = new java.util.ArrayList<>();

                java.util.Map<String, ?> all = prefs(ctx).getAll();
                for (java.util.Map.Entry<String, ?> e : all.entrySet()) {
                    String k = e.getKey();
                    if (k == null || !k.startsWith(KEY_PREFIX)) continue;

                    Object v = e.getValue();
                    if (!(v instanceof String)) continue;

                    Action a = Action.fromJson((String) v);
                    if (a == null) continue;

                    list.add(a);
                }

                list.sort((a, b) -> Long.compare(a.triggerAtMillis, b.triggerAtMillis));

                if (list.isEmpty()) {
                    Log.w(TAG, "ExpectedActionsXX <empty>");
                    return;
                }

                int idx = 1;
                for (Action a : list) {
                    long lateBy = (a.triggerAtMillis > 0) ? (nowMs - a.triggerAtMillis) : 0L;
                    Log.w(TAG,
                            "ExpectedActionsXX id(" + idx + ")=" + a.requestId +
                            " trigTime=" + a.triggerAtMillis +
                            " lateBy=" + lateBy + "ms"
                    );
                    idx++;
                }
            } catch (Throwable t) {
                Log.w(TAG, "ExpectedActionsXX dump failed: " + t);
            }
        }

        /**
         * Handle an incoming onReceive for {@code requestId}.
         *
         * Rules:
         * 1) If this (requestId, triggerAtMillis) was already handled -> ignore and remove the expected entry.
         * 2) Otherwise: execute + remove. Then execute any other actions planned within the next {@code windowMs}.
         *
         * This does NOT "predict" future alarms. It only uses the ExpectedActions store as ground truth.
         */
         boolean handleOnReceiveWindow(Context ctx,
                                       int requestId,
                                       long trigAt,
                                       long nowMs,
                                       long windowMs,
                                       ActionRunner runner) {
             final long windowStart = nowMs - 500;
             final long windowEnd   = nowMs + windowMs;

             // 1) immer: current id behandeln (damit handledByExpected=true wird)
             Action first = get(ctx, requestId);
             if (first == null) return false;

             // per Call nicht doppelt laufen lassen
             java.util.HashSet<Integer> ran = new java.util.HashSet<>();

             // helper
             java.util.function.Consumer<Action> runFull = (Action a) -> {
                 if (a == null) return;
                 if (a.isExecuted) return;             // schon erledigt
                 if (!ran.add(a.requestId)) return;   // in diesem Call schon gelaufen

                 runner.run(a, /*executeFull=*/true);

                 // persist "executed" als Dedupe
                 a.isExecuted = true;
                 setExecuted(ctx, a.requestId, true);
             };

             // A) wenn FIRST schon executed: nichts weiter (oder trotzdem scan, je nach Wunsch)
             if (!first.isExecuted) {
                 boolean inWindow = (first.triggerAtMillis >= windowStart && first.triggerAtMillis <= windowEnd);
                 if (inWindow) runFull.accept(first);
                 else return true; // wie von dir gewünscht: nur return true
             }

             // 2) NEU: alle anderen ExpectedActions im Fenster ebenfalls ausführen
             for (Action a : getAll(ctx)) { // getAll: alle gespeicherten ExpectedActions laden
                 if (a.requestId == requestId) continue; // first schon oben
                 boolean inWindow = (a.triggerAtMillis >= windowStart && a.triggerAtMillis <= windowEnd);
                 if (inWindow) {
                     runFull.accept(a);
                 }
             }
             return true;
         }


        private void persistLocked(Context ctx, Action a) {
            try {
                prefs(ctx).edit().putString(key(a.requestId), a.toJson()).apply();
            } catch (Throwable t) {
                Log.w(TAG, "ExpectedActions: persist failed id=" + a.requestId + ": " + t);
            }
        }

        @SuppressWarnings("unused")
        private synchronized int size() {
            return map.size();
        }

        // Immutable-ish data object (copy on read).
        // Inside ExpectedActions
        // Immutable-ish data object (copy on read).
        private static final class Action {
            final int requestId;
            final long triggerAtMillis;

            final String soundName;
            final float volume01;

            final String title;
            final String actionText;

            final String mode;
            final String fixedTime;
            final String startTime;
            final String endTime;
            int intervalSeconds;

            // NEW: execution marker (persisted)
            boolean isExecuted;   // default false on (new) schedules

            // Main ctor (allows explicit isExecute)
            Action(int requestId,
                   long triggerAtMillis,
                   String soundName,
                   float volume01,
                   String title,
                   String actionText,
                   String mode,
                   String fixedTime,
                   String startTime,
                   String endTime,
                   int intervalSeconds,
                   boolean isExecute) {
                this.requestId = requestId;
                this.triggerAtMillis = triggerAtMillis;
                this.soundName = soundName;
                this.volume01 = volume01;
                this.title = title;
                this.actionText = actionText;
                this.mode = mode;
                this.fixedTime = fixedTime;
                this.startTime = startTime;
                this.endTime = endTime;
                this.intervalSeconds = intervalSeconds;
                this.isExecuted = isExecuted;
            }

            // Convenience ctor used by scheduling side (defaults to false)
            Action(int requestId,
                   long triggerAtMillis,
                   String soundName,
                   float volume01,
                   String title,
                   String actionText,
                   String mode,
                   String fixedTime,
                   String startTime,
                   String endTime,
                   int intervalSeconds) {
                this(requestId, triggerAtMillis, soundName, volume01, title, actionText,
                     mode, fixedTime, startTime, endTime, intervalSeconds,
                     /*isExecute=*/false);
            }

            // Copy (keeps current isExecute)
            Action copy() {
                return new Action(
                        requestId,
                        triggerAtMillis,
                        soundName,
                        volume01,
                        title,
                        actionText,
                        mode,
                        fixedTime,
                        startTime,
                        endTime,
                        intervalSeconds,
                        isExecuted
                );
            }

            // Helper: return a copy with updated execute flag
            Action withExecuted(boolean executed) {
                return new Action(
                        requestId,
                        triggerAtMillis,
                        soundName,
                        volume01,
                        title,
                        actionText,
                        mode,
                        fixedTime,
                        startTime,
                        endTime,
                        intervalSeconds,
                        executed
                );
            }

            String toJson() {
                try {
                    JSONObject o = new JSONObject();
                    o.put("requestId", requestId);
                    o.put("triggerAtMillis", triggerAtMillis);

                    o.put("soundName", soundName);
                    o.put("volume01", (double) volume01);

                    o.put("title", title);
                    o.put("actionText", actionText);

                    o.put("mode", mode);
                    o.put("fixedTime", fixedTime);
                    o.put("startTime", startTime);
                    o.put("endTime", endTime);
                    o.put("intervalSeconds", intervalSeconds);

                    // NEW
                    o.put("isExecuted", isExecuted);

                    return o.toString();
                } catch (Throwable t) {
                    return null;
                }
            }

            static Action fromJson(String json) {
                try {
                    JSONObject o = new JSONObject(json);
                    return new Action(
                            o.optInt("requestId", -1),
                            o.optLong("triggerAtMillis", -1L),
                            o.optString("soundName", null),
                            (float) o.optDouble("volume01", 1.0),
                            o.optString("title", null),
                            o.optString("actionText", null),
                            o.optString("mode", null),
                            o.optString("fixedTime", null),
                            o.optString("startTime", null),
                            o.optString("endTime", null),
                            o.optInt("intervalSeconds", 0),
                            // NEW (default false if missing in old persisted entries)
                            o.optBoolean("isExecuted", false)
                    );
                } catch (Throwable t) {
                    return null;
                }
            }
        }
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        try {
            if (context == null || intent == null) {
                Log.e(TAG, "onReceive: context or intent is NULL");
                return;
            }

            final Context appCtx = context.getApplicationContext();

            final int requestId = intent.getIntExtra(
                    AlarmScheduler.EXTRA_REQUEST_ID,
                    intent.getIntExtra(AlarmScheduler.EXTRA_NOTIF_ID, -1)
            );
            Log.w(TAG, "ONRECEIVE id=" + requestId +
                  " now=" + System.currentTimeMillis() +
                  " trig=" + intent.getLongExtra(AlarmScheduler.EXTRA_TRIGGER_AT_MILLIS, -1) +
                  " lateBy=" + (System.currentTimeMillis() - intent.getLongExtra(AlarmScheduler.EXTRA_TRIGGER_AT_MILLIS, -1)) + "ms");
            EXPECTED_ACTIONS.logAllExpectedActions(appCtx, System.currentTimeMillis());

            final long trigAt = intent.getLongExtra(AlarmScheduler.EXTRA_TRIGGER_AT_MILLIS, -1L);
            final long nowMs = System.currentTimeMillis();

            // Use ExpectedActions to dedupe + execute this action and any others planned in the next 5s.
            final boolean handledByExpected = EXPECTED_ACTIONS.handleOnReceiveWindow(
                appCtx,
                requestId,
                trigAt,
                nowMs,
                /*windowMs=*/5000L,
                (ExpectedActions.Action a,boolean executeFull) -> {
                    // Build a synthetic intent containing all extras needed by the existing execution path.
                    Intent ii = new Intent();
                    ii.putExtra(AlarmScheduler.EXTRA_REQUEST_ID, a.requestId);
                    ii.putExtra(AlarmScheduler.EXTRA_NOTIF_ID, a.requestId); // legacy
                    ii.putExtra(AlarmScheduler.EXTRA_TRIGGER_AT_MILLIS, a.triggerAtMillis);

                    ii.putExtra(AlarmScheduler.EXTRA_SOUND_NAME, a.soundName);
                    ii.putExtra(AlarmScheduler.EXTRA_VOLUME01, a.volume01);

                    ii.putExtra(AlarmScheduler.EXTRA_TITLE, a.title);
                    ii.putExtra(AlarmScheduler.EXTRA_TEXT, a.actionText);

                    ii.putExtra(AlarmScheduler.EXTRA_MODE, a.mode);
                    ii.putExtra(AlarmScheduler.EXTRA_FIXED_TIME, a.fixedTime);
                    ii.putExtra(AlarmScheduler.EXTRA_START_TIME, a.startTime);
                    ii.putExtra(AlarmScheduler.EXTRA_END_TIME, a.endTime);
                    ii.putExtra(AlarmScheduler.EXTRA_INTERVAL_SECONDS, a.intervalSeconds);

                    if (!executeFull) {
                        // NUR reschedule, sonst nichts
                        Log.w(TAG, "ExpectedActionsXX: ignore deleted execut id=" + a.requestId);
                        AlarmScheduler.rescheduleNextFromIntent(appCtx, ii);
                        return;
                    }


                    logAudioState(appCtx);
                    showNotification(appCtx, ii, a.requestId);
                    Log.w(TAG, "ExpectedActionsXX: execut id=" + a.requestId);

                    // Interval reschedule (does nothing for fixed-time)
                    AlarmScheduler.rescheduleNextFromIntent(appCtx, ii);

                    // Play sequentially
                    enqueueAndPlay(appCtx, a);
                }
            );
        } catch (Throwable t) {
            Log.e(TAG, "onReceive failed", t);
        }
    }

    private static void enqueueAndPlay(Context ctx, ExpectedActions.Action a) {
        if (ctx == null || a == null) return;
        synchronized (PLAY_LOCK) {
            PLAY_Q.addLast(a);
            if (PLAYING) return;
            PLAYING = true;
        }
        playNextLocked(ctx.getApplicationContext());
    }

    private static void playNextLocked(Context appCtx) {
        final ExpectedActions.Action next;
        synchronized (PLAY_LOCK) {
            next = PLAY_Q.pollFirst();
            if (next == null) {
                PLAYING = false;
                return;
            }
        }

        // Play one sound; when done -> play next
        playShortBeep(appCtx, next.soundName, next.volume01, () -> playNextLocked(appCtx));
    }

    // Overload with completion callback (used by sequential queue)
    private static void playShortBeep(Context ctx, String soundName, float volume01, Runnable onDone) {
        final PowerManager.WakeLock[] wlRef = new PowerManager.WakeLock[1];
        final MediaPlayer[] mpRef = new MediaPlayer[1];
        final boolean[] doneOnce = new boolean[]{false};

        final Runnable finish = () -> {
            if (doneOnce[0]) return;
            doneOnce[0] = true;
            try { if (onDone != null) onDone.run(); } catch (Throwable ignored) {}
        };

        try {
            wlRef[0] = acquireShortWakelock(ctx);

            volume01 = clamp01(volume01);
            if (volume01 <= 0.0f) {
                Log.w(TAG, "playShortBeep: MUTED (vol=0) -> skip soundName=" + soundName);
                releaseWakelock(wlRef[0]);
                finish.run();
                return;
            }

            int resId = 0;
            if (soundName != null && !soundName.trim().isEmpty()) {
                resId = ctx.getResources().getIdentifier(soundName, "raw", ctx.getPackageName());
                Log.w(TAG, "resolve raw '" + soundName + "' -> resId=" + resId);
            }
            if (resId == 0) {
                Log.w(TAG, "raw resource not found for '" + soundName + "', fallback to 'bell'");
                resId = ctx.getResources().getIdentifier("bell", "raw", ctx.getPackageName());
                Log.w(TAG, "resolve raw 'bell' -> resId=" + resId);
            }
            if (resId == 0) {
                Log.e(TAG, "No usable raw sound found (soundName=" + soundName + ")");
                releaseWakelock(wlRef[0]);
                finish.run();
                return;
            }

            MediaPlayer mp = createAlarmPlayerFromRaw(ctx, resId);
            mpRef[0] = mp;

            try { mp.setVolume(volume01, volume01); } catch (Throwable ignored) {}

            final Handler h = new Handler(Looper.getMainLooper());

            mp.setOnCompletionListener(m -> {
                Log.w(TAG, "MediaPlayer: onCompletion");
                safeStopRelease(mpRef[0]);
                releaseWakelock(wlRef[0]);
                finish.run();
            });

            mp.setOnErrorListener((m, what, extra) -> {
                Log.e(TAG, "MediaPlayer: onError what=" + what + " extra=" + extra);
                safeStopRelease(mpRef[0]);
                releaseWakelock(wlRef[0]);
                finish.run();
                return true;
            });

            // Hard stop
            h.postDelayed(() -> {
                Log.w(TAG, "playShortBeep: HARD STOP after " + BEEP_MAX_MS + "ms. isPlaying=" + safeIsPlaying(mpRef[0]));
                safeStopRelease(mpRef[0]);
                releaseWakelock(wlRef[0]);
                finish.run();
            }, BEEP_MAX_MS);

            Log.w(TAG, "playShortBeep: START calling mp.start()");
            mp.start();

        } catch (Throwable t) {
            Log.e(TAG, "playShortBeep failed", t);
            safeStopRelease(mpRef[0]);
            releaseWakelock(wlRef[0]);
            finish.run();
        }
    }


    // -------------------- NOTIFICATION --------------------
    private static void ensureNotificationChannel(Context ctx) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm == null) return;

            NotificationChannel ch = nm.getNotificationChannel(CH_ID);
            if (ch != null) return;

            NotificationChannel channel = new NotificationChannel(
                    CH_ID, CH_NAME, NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription(CH_DESC);

            // force silent
            channel.setSound(null, null);
            channel.enableVibration(false);
            channel.enableLights(false);

            nm.createNotificationChannel(channel);
        }
    }

    private static void showNotification(Context ctx, Intent intent, int notifId) {
        try {
            ensureNotificationChannel(ctx);

            String title = intent.getStringExtra(AlarmScheduler.EXTRA_TITLE);
            String text  = intent.getStringExtra(AlarmScheduler.EXTRA_TEXT);

            if (title == null || title.trim().isEmpty()) title = "DailyActions";
            if (text == null) text = "";

            NotificationCompat.Builder b = new NotificationCompat.Builder(ctx, CH_ID)
                    .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                    .setContentTitle(title)
                    .setContentText(text)
                    .setPriority(NotificationCompat.PRIORITY_LOW)
                    .setCategory(NotificationCompat.CATEGORY_REMINDER)
                    .setAutoCancel(true)
                    .setSilent(true);

            NotificationManagerCompat.from(ctx).notify(notifId, b.build());

        } catch (Throwable t) {
            Log.w(TAG, "showNotification failed: " + t);
        }
    }

    // -------------------- AUDIO --------------------
    private static float clamp01(float v) {
        if (v < 0f) return 0f;
        if (v > 1f) return 1f;
        return v;
    }

    private static PowerManager.WakeLock acquireShortWakelock(Context ctx) {
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            if (pm == null) return null;

            PowerManager.WakeLock wl = pm.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    ctx.getPackageName() + ":AlarmReceiver"
            );
            wl.setReferenceCounted(false);
            wl.acquire(WAKELOCK_MS);
            Log.w(TAG, "WakeLock acquired for " + WAKELOCK_MS + "ms");
            return wl;
        } catch (Throwable t) {
            Log.w(TAG, "WakeLock acquire failed: " + t);
            return null;
        }
    }

    private static void releaseWakelock(PowerManager.WakeLock wl) {
        try {
            if (wl != null && wl.isHeld()) {
                wl.release();
                Log.w(TAG, "WakeLock released");
            }
        } catch (Throwable ignored) {}
    }

    private static void playShortBeep(Context ctx, String soundName, float volume01) {
        final PowerManager.WakeLock[] wlRef = new PowerManager.WakeLock[1];
        final MediaPlayer[] mpRef = new MediaPlayer[1];

        try {
            wlRef[0] = acquireShortWakelock(ctx);

            volume01 = clamp01(volume01);
            if (volume01 <= 0.0f) {
                Log.w(TAG, "playShortBeep: MUTED (vol=0) -> skip soundName=" + soundName);
                releaseWakelock(wlRef[0]);
                return;
            }

            int resId = 0;
            if (soundName != null && !soundName.trim().isEmpty()) {
                resId = ctx.getResources().getIdentifier(soundName, "raw", ctx.getPackageName());
                Log.w(TAG, "resolve raw '" + soundName + "' -> resId=" + resId);
            }
            if (resId == 0) {
                Log.w(TAG, "raw resource not found for '" + soundName + "', fallback to 'bell'");
                resId = ctx.getResources().getIdentifier("bell", "raw", ctx.getPackageName());
                Log.w(TAG, "resolve raw 'bell' -> resId=" + resId);
            }
            if (resId == 0) {
                Log.e(TAG, "No usable raw sound found (soundName=" + soundName + ")");
                releaseWakelock(wlRef[0]);
                return;
            }

            MediaPlayer mp = createAlarmPlayerFromRaw(ctx, resId);
            mpRef[0] = mp;

            try { mp.setVolume(volume01, volume01); } catch (Throwable ignored) {}

            final Handler h = new Handler(Looper.getMainLooper());

            mp.setOnCompletionListener(m -> {
                Log.w(TAG, "MediaPlayer: onCompletion");
                safeStopRelease(mpRef[0]);
                releaseWakelock(wlRef[0]);
            });

            mp.setOnErrorListener((m, what, extra) -> {
                Log.e(TAG, "MediaPlayer: onError what=" + what + " extra=" + extra);
                safeStopRelease(mpRef[0]);
                releaseWakelock(wlRef[0]);
                return true;
            });

            // Hard stop
            h.postDelayed(() -> {
                Log.w(TAG, "playShortBeep: HARD STOP after " + BEEP_MAX_MS + "ms. isPlaying=" + safeIsPlaying(mpRef[0]));
                safeStopRelease(mpRef[0]);
                releaseWakelock(wlRef[0]);
            }, BEEP_MAX_MS);

            Log.w(TAG, "playShortBeep: START calling mp.start()");
            mp.start();

        } catch (Throwable t) {
            Log.e(TAG, "playShortBeep failed", t);
            safeStopRelease(mpRef[0]);
            releaseWakelock(wlRef[0]);
        }
    }

    private static MediaPlayer createAlarmPlayerFromRaw(Context ctx, int resId) throws Exception {
        Log.w(TAG, "createAlarmPlayerFromRaw: resId=" + resId);

        MediaPlayer mp = new MediaPlayer();

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            AudioAttributes aa = new AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build();
            mp.setAudioAttributes(aa);
            Log.w(TAG, "AudioAttributes set: USAGE_ALARM / SONIFICATION");
        } else {
            mp.setAudioStreamType(AudioManager.STREAM_ALARM);
            Log.w(TAG, "AudioStreamType set: STREAM_ALARM (pre-L)");
        }

        AssetFileDescriptor afd = ctx.getResources().openRawResourceFd(resId);
        if (afd == null) throw new IllegalStateException("openRawResourceFd returned null for resId=" + resId);

        Log.w(TAG, "afd: startOffset=" + afd.getStartOffset() + " length=" + afd.getLength());

        mp.setDataSource(afd.getFileDescriptor(), afd.getStartOffset(), afd.getLength());
        afd.close();

        Log.w(TAG, "MediaPlayer: preparing...");
        mp.prepare();
        Log.w(TAG, "MediaPlayer: prepared OK");

        return mp;
    }

    private static boolean safeIsPlaying(MediaPlayer mp) {
        try { return mp != null && mp.isPlaying(); } catch (Throwable ignored) { return false; }
    }

    private static void safeStopRelease(MediaPlayer mp) {
        if (mp == null) return;
        try {
            try { mp.setOnCompletionListener(null); } catch (Throwable ignored) {}
            try { mp.setOnErrorListener(null); } catch (Throwable ignored) {}
            try {
                if (mp.isPlaying()) mp.stop();
            } catch (Throwable ignored) {}
            try { mp.reset(); } catch (Throwable ignored) {}
            try { mp.release(); } catch (Throwable ignored) {}
        } catch (Throwable ignored) {}
    }

    // -------------------- AUDIO STATE LOG --------------------
    private static void logAudioState(Context ctx) {
        try {
            AudioManager am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
            if (am == null) return;

            int mode = am.getMode();
            boolean musicActive = am.isMusicActive();

            int volAlarm = am.getStreamVolume(AudioManager.STREAM_ALARM);
            int maxAlarm = am.getStreamMaxVolume(AudioManager.STREAM_ALARM);

            int volMusic = am.getStreamVolume(AudioManager.STREAM_MUSIC);
            int maxMusic = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC);

            boolean mutedAlarm = false;
            boolean mutedMusic = false;
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    mutedAlarm = am.isStreamMute(AudioManager.STREAM_ALARM);
                    mutedMusic = am.isStreamMute(AudioManager.STREAM_MUSIC);
                }
            } catch (Throwable ignored) {}

            Log.w(TAG, "AUDIO state: mode=" + mode
                    + " musicActive=" + musicActive
                    + " ALARM vol=" + volAlarm + "/" + maxAlarm + " muted=" + mutedAlarm
                    + " MUSIC vol=" + volMusic + "/" + maxMusic + " muted=" + mutedMusic
                    + " ringerMode=" + am.getRingerMode()
            );
        } catch (Throwable t) {
            Log.w(TAG, "logAudioState failed: " + t);
        }
    }
}
