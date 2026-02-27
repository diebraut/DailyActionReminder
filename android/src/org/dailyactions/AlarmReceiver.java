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

    // --- PLAYBACK STATE (global) ---
    private static final Object PLAY_LOCK = new Object();
    // Currently playing sound (so cancel(id) can stop it immediately)
    private static int s_playingRequestId = -1;
    private static MediaPlayer s_playingMp = null;
    private static PowerManager.WakeLock s_playingWl = null;
    private static Handler s_playingHandler = null;
    private static Runnable s_playingHardStop = null;
    private static Runnable s_playingFinish = null;

    // je nach deiner Implementierung: MediaPlayer oder SoundPool-StreamId
    private static android.media.MediaPlayer s_mp = null;

    private static final class QueueItem {
        final SoundEvent e;
        final int intervalCapMs; // -1 => no cap
        QueueItem(SoundEvent e, int intervalCapMs) {
            this.e = e;
            this.intervalCapMs = intervalCapMs;
        }
    }

    private static final java.util.ArrayDeque<QueueItem> PLAY_Q = new java.util.ArrayDeque<>();
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

    public static void stopSoundForRequestId(Context ctx, int requestId) {
        if (ctx == null) return;
        if (requestId <= 0) return;

        final Context app = ctx.getApplicationContext();

        MediaPlayer mpToStop = null;

        synchronized (PLAY_LOCK) {
            // 1) queued items dieser requestId entfernen (PLAY_Q enthält QueueItem, NICHT SoundEvent)
            if (!PLAY_Q.isEmpty()) {
                final java.util.ArrayDeque<QueueItem> kept = new java.util.ArrayDeque<>();
                while (!PLAY_Q.isEmpty()) {
                    QueueItem qi = PLAY_Q.pollFirst();
                    if (qi == null) continue;

                    final SoundEvent e = qi.e;
                    if (e != null && e.requestId == requestId) {
                        Log.w(TAG, "stopSoundForRequestId: drop queued id=" + requestId);
                    } else {
                        kept.addLast(qi);
                    }
                }
                PLAY_Q.addAll(kept);
            }

            // 2) aktuell spielenden Ton stoppen, wenn es derselbe requestId ist
            if (s_playingRequestId == requestId) {
                Log.w(TAG, "stopSoundForRequestId: stopping CURRENT id=" + requestId);

                mpToStop = s_mp;

                // refs löschen
                s_mp = null;
                s_playingRequestId = -1;

                // Queue darf weiterlaufen
                PLAYING = false;
            }
        }

        // außerhalb des Locks stoppen
        try { safeStopRelease(mpToStop); } catch (Throwable ignored) {}

        // Queue fortsetzen (falls noch etwas drin ist)
        try { playNextLocked(app); } catch (Throwable ignored) {}
    }

    /**
     * Called from AlarmScheduler.cancel(...) where no Context is available.
     * Stops the currently playing sound for the given requestId and removes queued items.
     * (It cannot continue the queue because it has no Context.)
     */
    public static void stopPlaying(int requestId) {
        if (requestId <= 0) return;

        MediaPlayer mpToStop = null;
        PowerManager.WakeLock wlToRelease = null;
        Handler hToCancel = null;
        Runnable hardStopToCancel = null;
        Runnable finishToRun = null;

        synchronized (PLAY_LOCK) {
            // queued items entfernen
            if (!PLAY_Q.isEmpty()) {
                final java.util.ArrayDeque<QueueItem> kept = new java.util.ArrayDeque<>();
                while (!PLAY_Q.isEmpty()) {
                    QueueItem qi = PLAY_Q.pollFirst();
                    if (qi == null) continue;
                    final SoundEvent e = qi.e; // wichtig: e
                    if (e != null && e.requestId == requestId) {
                        Log.w(TAG, "stopPlaying: drop queued id=" + requestId);
                    } else {
                        kept.addLast(qi);
                    }
                }
                PLAY_Q.addAll(kept);
            }

            // aktuell spielenden Ton stoppen
            if (s_playingRequestId == requestId) {
                Log.w(TAG, "stopPlaying: stopping CURRENT id=" + requestId);

                mpToStop = s_playingMp;
                wlToRelease = s_playingWl;
                hToCancel = s_playingHandler;
                hardStopToCancel = s_playingHardStop;
                finishToRun = s_playingFinish;

                s_playingMp = null;
                s_playingWl = null;
                s_playingHandler = null;
                s_playingHardStop = null;
                s_playingFinish = null;
                s_playingRequestId = -1;

                PLAYING = false;
            }
        }

        // außerhalb des Locks stoppen
        try {
            if (hToCancel != null && hardStopToCancel != null) {
                try { hToCancel.removeCallbacks(hardStopToCancel); } catch (Throwable ignored) {}
            }
        } catch (Throwable ignored) {}

        try { safeStopRelease(mpToStop); } catch (Throwable ignored) {}
        try { releaseWakelock(wlToRelease); } catch (Throwable ignored) {}
        try { if (finishToRun != null) finishToRun.run(); } catch (Throwable ignored) {}
    }

    @Override
    public void onReceive(Context context, Intent intent) {
        try {
            final Context appCtx = context.getApplicationContext();

            if (context == null || intent == null) {
                Log.e(TAG, "onReceive: context or intent is NULL");
                return;
            }

            final int requestId = intent.getIntExtra(
                    AlarmScheduler.EXTRA_REQUEST_ID,
                    intent.getIntExtra(AlarmScheduler.EXTRA_NOTIF_ID, -1)
            );
            PowerManager pm = (PowerManager) appCtx.getSystemService(Context.POWER_SERVICE);
            boolean interactive = pm != null && pm.isInteractive();
            Log.w(TAG, "ONRECEIVE id=" + requestId + " interactive=" + interactive + " now=" + new java.util.Date());

            Log.w(TAG, "ONRECEIVE id=" + requestId +
                  " duration=" + intent.getIntExtra(AlarmScheduler.EXTRA_DURATION_SOUND, 0) +
                  " volume=" + intent.getFloatExtra(AlarmScheduler.EXTRA_VOLUME01, 1f) +
                  " trig=" + intent.getLongExtra(AlarmScheduler.EXTRA_TRIGGER_AT_MILLIS, -1) +
                  " lateBy=" + (System.currentTimeMillis() - intent.getLongExtra(AlarmScheduler.EXTRA_TRIGGER_AT_MILLIS, -1)) + "ms");
            logAudioState(appCtx);
            showNotification(appCtx, intent, requestId);
            Log.w(TAG, "ExpectedActionsXX: execut id=" + requestId);

            // Interval reschedule (does nothing for fixed-time)
            Log.w(TAG, "ExpectedActionsXX: rescheduleNextFromIntent id=" + requestId);
            AlarmScheduler.rescheduleNextFromIntent(appCtx, intent);

            SoundEvent e = new SoundEvent(
                    requestId,
                    intent.getStringExtra(AlarmScheduler.EXTRA_SOUND_NAME),
                    intent.getFloatExtra(AlarmScheduler.EXTRA_VOLUME01, 1.0f),
                    intent.getIntExtra(AlarmScheduler.EXTRA_DURATION_SOUND, 0)
            );

            // intervalCapMs nur bei mode=interval, sonst -1
            final String mode = intent.getStringExtra(AlarmScheduler.EXTRA_MODE);
            final int intervalCapMs;
            if ("interval".equals(mode)) {
                final int intervalSec = intent.getIntExtra(AlarmScheduler.EXTRA_INTERVAL_SECONDS, 0);
                intervalCapMs = (intervalSec > 0) ? (intervalSec * 1000) : -1;
            } else {
                intervalCapMs = -1;
            }

            enqueueAndPlay(appCtx, e, intervalCapMs);        } catch (Throwable t) {
            Log.e(TAG, "onReceive failed", t);
        }
    }

    private static void enqueueAndPlay(Context ctx, SoundEvent e, int intervalCapMs) {
        if (ctx == null || e == null) return;
        synchronized (PLAY_LOCK) {
            PLAY_Q.addLast(new QueueItem(e, intervalCapMs));
            if (PLAYING) return;
            PLAYING = true;
        }
        playNextLocked(ctx.getApplicationContext());
    }

    private static void playNextLocked(Context appCtx) {
        final QueueItem qi;
        synchronized (PLAY_LOCK) {
            qi = PLAY_Q.pollFirst();
            if (qi == null) {
                PLAYING = false;
                return;
            }
        }

        final SoundEvent next = qi.e;

        // duration: hundredth-minutes => ms (1/100 min = 600ms)
        int durMs = (next.duration > 0) ? (next.duration * 600) : 0;

        // Cap: darf nicht länger als Interval sein (nur wenn intervalCapMs > 0)
        if (qi.intervalCapMs > 0 && durMs > 0) {
            durMs = Math.min(durMs, qi.intervalCapMs);
        }

        // Fallback: wenn duration nicht gesetzt -> bisheriges Verhalten
        final int stopAfterMs = (durMs > 0) ? durMs : BEEP_MAX_MS;

        playShortBeep(appCtx, next.requestId, next.soundName, next.volume01, stopAfterMs, () -> playNextLocked(appCtx));
    }    // Overload with completion callback (used by sequential queue)

    // Wrapper: "einmal kurz" (ohne erzwungene Dauer)
    private static void playShortBeep(Context ctx,int requestId, String soundName, float volume01) {
        playShortBeep(ctx,requestId, soundName, volume01, /*stopAfterMs=*/0, /*onDone=*/null);
    }

    // Optionaler Wrapper: mit Dauer aber ohne Callback
    private static void playShortBeep(Context ctx, int requestId, String soundName, float volume01, int stopAfterMs) {
        playShortBeep(ctx, requestId, soundName, volume01, stopAfterMs, /*onDone=*/null);
    }

    // EINZIGE Implementierung
    private static void playShortBeep(Context ctx, int requestId, String soundName, float volume01, int stopAfterMs, Runnable onDone) {
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

            // ------------------------------------------------------------
            // PATCH START: durationSound korrekt (mehrfach abspielen)
            // - stopAfterMs <= 0  => Sound 1x abspielen, Cleanup bei Completion
            // - stopAfterMs > 0   => Sound loopen + HardStop nach stopAfterMs
            // ------------------------------------------------------------
            final boolean useHardStop = (stopAfterMs > 0);

            try { mp.setLooping(useHardStop); } catch (Throwable ignored) {}

            final Runnable clearPlayingState = () -> {
                synchronized (PLAY_LOCK) {
                    if (s_playingRequestId == requestId) {
                        s_playingRequestId = -1;
                        s_playingMp = null;
                        s_playingWl = null;
                        s_playingHandler = null;
                        s_playingHardStop = null;
                        s_playingFinish = null;
                    }
                    PLAYING = false;
                }
            };

            final Runnable hardStop = () -> {
                Log.w(TAG, "playShortBeep: HARD STOP after " + stopAfterMs
                        + "ms. isPlaying=" + safeIsPlaying(mpRef[0]));
                safeStopRelease(mpRef[0]);
                releaseWakelock(wlRef[0]);
                clearPlayingState.run();
                finish.run();
            };

            // Bei "einmal abspielen" cleanup über Completion
            try {
                mp.setOnCompletionListener(m -> {
                    Log.w(TAG, "playShortBeep: COMPLETED requestId=" + requestId);
                    safeStopRelease(mpRef[0]);
                    releaseWakelock(wlRef[0]);
                    clearPlayingState.run();
                    finish.run();
                });
            } catch (Throwable ignored) {}

            synchronized (PLAY_LOCK) {
                s_playingRequestId = requestId;
                s_playingMp = mpRef[0];
                s_playingWl = wlRef[0];
                s_playingHandler = h;
                s_playingHardStop = useHardStop ? hardStop : null;
                s_playingFinish = finish;
            }

            if (useHardStop) {
                h.postDelayed(hardStop, stopAfterMs);
            }

            Log.w(TAG, "playShortBeep: START calling mp.start() stopAfterMs=" + stopAfterMs
                    + " loop=" + useHardStop);
            mp.start();
            // PATCH END
        } catch (Throwable t) {
            Log.e(TAG, "playShortBeep failed", t);
            safeStopRelease(mpRef[0]);
            releaseWakelock(wlRef[0]);
            synchronized (PLAY_LOCK) {
                if (s_playingRequestId == requestId) {
                    s_playingRequestId = -1;
                    s_playingMp = null;
                    s_playingWl = null;
                    s_playingHandler = null;
                    s_playingHardStop = null;
                    s_playingFinish = null;
                }
                PLAYING = false;
            }
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
