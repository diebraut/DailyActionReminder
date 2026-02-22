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
    private static final java.util.ArrayDeque<SoundEvent> PLAY_Q = new java.util.ArrayDeque<>();
    private static boolean PLAYING = false;

    // Immutable-ish data object (copy on read).
    // Inside ExpectedActions
    // Immutable-ish data object (copy on read).
    private static final class SoundEvent {
        final int requestId;
        final String soundName;
        final float  volume01;
        final int duration;

        // Main ctor (allows explicit isExecute)
        SoundEvent(int requestId,
               String soundName,
               final float volume01,
               int    duration) {
            this.requestId  = requestId;
            this.soundName = soundName;
            this.volume01 = volume01;
            this.duration = duration;
        }

        // Copy (keeps current isExecute)
        SoundEvent copy() {
            return new SoundEvent(
                    requestId,
                    soundName,
                    volume01,
                    duration
            );
        }


        String toJson() {
            try {
                JSONObject o = new JSONObject();
                o.put("requestId", requestId);
                o.put("soundName", soundName);
                o.put("volume01", (double) volume01);
                o.put("duration", duration);

                return o.toString();
            } catch (Throwable t) {
                return null;
            }
        }

        static SoundEvent fromJson(String json) {
            try {
                JSONObject o = new JSONObject(json);
                return new SoundEvent(
                        o.optInt("requestId", -1),
                        o.optString("soundName", null),
                        (float) o.optDouble("volume01", 1.0),
                        o.optInt("duration", 1)
                );
            } catch (Throwable t) {
                return null;
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
            logAudioState(appCtx);
            showNotification(appCtx, intent, requestId);
            Log.w(TAG, "ExpectedActionsXX: execut id=" + requestId);

            // Interval reschedule (does nothing for fixed-time)
            Log.w(TAG, "ExpectedActionsXX: rescheduleNextFromIntent id=" + requestId);
            AlarmScheduler.rescheduleNextFromIntent(appCtx, intent);

            // Play sequentially
            SoundEvent e = new SoundEvent(requestId,intent.getStringExtra(AlarmScheduler.EXTRA_SOUND_NAME),
                                          intent.getFloatExtra(AlarmScheduler.EXTRA_VOLUME01,1.0f),intent.getIntExtra(AlarmScheduler.EXTRA_DURATION_SOUND,0));
            enqueueAndPlay(appCtx, e);


            /*


            // Use ExpectedActions to dedupe + execute this action and any others planned in the next 5s.
            final boolean handledByExpected = EXPECTED_ACTIONS.handleOnReceiveWindow(
                appCtx,
                requestId,
                trigAt,
                nowMs,
                5000L,
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
                    Log.w(TAG, "ExpectedActionsXX: rescheduleNextFromIntent id=" + a.requestId);
                    AlarmScheduler.rescheduleNextFromIntent(appCtx, ii);

                    // Play sequentially
                    enqueueAndPlay(appCtx, a);
                }
            );
            */
        } catch (Throwable t) {
            Log.e(TAG, "onReceive failed", t);
        }
    }

    private static void enqueueAndPlay(Context ctx, SoundEvent e) {
        if (ctx == null || e == null) return;
        synchronized (PLAY_LOCK) {
            PLAY_Q.addLast(e);
            if (PLAYING) return;
            PLAYING = true;
        }
        playNextLocked(ctx.getApplicationContext());
    }

    private static void playNextLocked(Context appCtx) {
        final SoundEvent next;
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
