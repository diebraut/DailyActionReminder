package org.dailyactions;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.res.AssetFileDescriptor;

import android.app.PendingIntent; // nur falls du es irgendwo brauchst; hier nicht nötig
import android.media.AudioAttributes;
import android.media.AudioManager;
import android.media.MediaPlayer;

import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.os.PowerManager;

import android.util.Log;

public class AlarmReceiver extends BroadcastReceiver {

    private static final String TAG = "AlarmReceiver";

    // Hard stop damit "kurz piepen" garantiert kurz bleibt
    private static final int BEEP_MAX_MS = 1200;     // 1.2s
    private static final int WAKELOCK_MS = 5000;     // 5s (nur damit CPU kurz wach bleibt)

    @Override
    public void onReceive(Context context, Intent intent) {
        final PendingResult pr = goAsync();

        try {
            if (context == null || intent == null) {
                Log.e(TAG, "onReceive: context or intent is NULL");
                safeFinish(pr);
                return;
            }

            final int requestId = intent.getIntExtra(
                    AlarmScheduler.EXTRA_REQUEST_ID,
                    intent.getIntExtra(AlarmScheduler.EXTRA_NOTIF_ID, -1)
            );

            final String soundName = intent.getStringExtra(AlarmScheduler.EXTRA_SOUND_NAME);
            final float volume01 = intent.getFloatExtra(AlarmScheduler.EXTRA_VOLUME01, 1.0f);

            Log.e(TAG, "### onReceive ###"
                    + " action=" + intent.getAction()
                    + " requestId=" + requestId
                    + " soundName=" + soundName
                    + " vol=" + volume01
                    + " sdk=" + Build.VERSION.SDK_INT
                    + " time=" + System.currentTimeMillis()
            );

            logAudioState(context);

            playShortBeep(context.getApplicationContext(), soundName, volume01, pr);
            try {
                // alle 10 Sekunden neu planen (Test)
                long next = System.currentTimeMillis() + 10_000;
                Log.w(TAG, "SELF-RESCHEDULE next=" + next);

                AlarmScheduler.scheduleWithParams(
                        context.getApplicationContext(),
                        next,
                        soundName != null ? soundName : "bell",
                        requestId + 1,                 // neue ID!
                        "TEST",
                        "SELF RESCHEDULE",
                        "test",
                        "",
                        "",
                        "",
                        0,
                        volume01
                );
            } catch (Throwable t) {
                Log.e(TAG, "SELF-RESCHEDULE failed", t);
            }


        } catch (Throwable t) {
            Log.e(TAG, "onReceive failed", t);
            safeFinish(pr);
        }
    }

    private static void logAudioState(Context ctx) {
        try {
            AudioManager am = (AudioManager) ctx.getSystemService(Context.AUDIO_SERVICE);
            if (am == null) {
                Log.w(TAG, "AudioManager == null");
                return;
            }

            int mode = am.getMode();
            boolean musicActive = am.isMusicActive();
            int alarmVol = am.getStreamVolume(AudioManager.STREAM_ALARM);
            int alarmMax = am.getStreamMaxVolume(AudioManager.STREAM_ALARM);
            int musicVol = am.getStreamVolume(AudioManager.STREAM_MUSIC);
            int musicMax = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC);
            boolean mutedAlarm = false;
            boolean mutedMusic = false;

            if (Build.VERSION.SDK_INT >= 23) {
                mutedAlarm = am.isStreamMute(AudioManager.STREAM_ALARM);
                mutedMusic = am.isStreamMute(AudioManager.STREAM_MUSIC);
            }

            Log.w(TAG, "AUDIO state:"
                    + " mode=" + mode
                    + " musicActive=" + musicActive
                    + " ALARM vol=" + alarmVol + "/" + alarmMax + " muted=" + mutedAlarm
                    + " MUSIC vol=" + musicVol + "/" + musicMax + " muted=" + mutedMusic
                    + " ringerMode=" + am.getRingerMode()
            );
        } catch (Throwable t) {
            Log.w(TAG, "logAudioState failed: " + t);
        }
    }

    private static void playShortBeep(Context ctx, String soundName, float volume01, PendingResult pr) {
        final PowerManager.WakeLock[] wlRef = new PowerManager.WakeLock[1];
        final MediaPlayer[] mpRef = new MediaPlayer[1];

        try {
            wlRef[0] = acquireShortWakelock(ctx);

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
                Log.e(TAG, "No usable raw sound found (soundName=" + soundName + "). " +
                        "Check: app/src/main/res/raw/bell.(mp3|wav|ogg)");
                releaseWakelock(wlRef[0]);
                safeFinish(pr);
                return;
            }

            volume01 = clamp01(volume01);

            MediaPlayer mp = createAlarmPlayerFromRaw(ctx, resId);
            mpRef[0] = mp;

            try { mp.setVolume(volume01, volume01); } catch (Throwable ignored) {}

            Log.w(TAG, "playShortBeep: PREPARED. durationMs=" + safeDuration(mp)
                    + " vol=" + volume01
                    + " stopAfterMs=" + BEEP_MAX_MS);

            final Handler h = new Handler(Looper.getMainLooper());

            mp.setOnPreparedListener(m -> Log.w(TAG, "MediaPlayer: onPrepared"));
            mp.setOnCompletionListener(m -> {
                Log.w(TAG, "MediaPlayer: onCompletion");
                safeStopRelease(mpRef[0]);
                releaseWakelock(wlRef[0]);
                safeFinish(pr);
            });

            mp.setOnErrorListener((m, what, extra) -> {
                Log.e(TAG, "MediaPlayer: onError what=" + what + " extra=" + extra);
                safeStopRelease(mpRef[0]);
                releaseWakelock(wlRef[0]);
                safeFinish(pr);
                return true;
            });

            // Hard stop (falls Sound länger ist oder Completion nicht kommt)
            h.postDelayed(() -> {
                Log.w(TAG, "playShortBeep: HARD STOP after " + BEEP_MAX_MS + "ms. isPlaying=" + safeIsPlaying(mpRef[0]));
                safeStopRelease(mpRef[0]);
                releaseWakelock(wlRef[0]);
                safeFinish(pr);
            }, BEEP_MAX_MS);

            Log.w(TAG, "playShortBeep: START calling mp.start()");
            mp.start();
            Log.w(TAG, "playShortBeep: START returned. isPlaying=" + safeIsPlaying(mp));

        } catch (Throwable t) {
            Log.e(TAG, "playShortBeep failed", t);
            safeStopRelease(mpRef[0]);
            releaseWakelock(wlRef[0]);
            safeFinish(pr);
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

    private static int safeDuration(MediaPlayer mp) {
        try { return mp.getDuration(); } catch (Throwable t) { return -1; }
    }

    private static boolean safeIsPlaying(MediaPlayer mp) {
        try { return mp != null && mp.isPlaying(); } catch (Throwable t) { return false; }
    }

    private static float clamp01(float v) {
        if (v < 0f) return 0f;
        if (v > 1f) return 1f;
        return v;
    }

    private static PowerManager.WakeLock acquireShortWakelock(Context ctx) {
        try {
            PowerManager pm = (PowerManager) ctx.getSystemService(Context.POWER_SERVICE);
            if (pm == null) return null;

            PowerManager.WakeLock wl = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "DailyActions:AlarmBeep");
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
        } catch (Throwable t) {
            Log.w(TAG, "WakeLock release failed: " + t);
        }
    }

    private static void safeStopRelease(MediaPlayer mp) {
        if (mp == null) return;
        try {
            if (mp.isPlaying()) mp.stop();
        } catch (Throwable ignored) { }
        try { mp.release(); } catch (Throwable ignored) { }
    }

    private static void safeFinish(PendingResult pr) {
        try { if (pr != null) pr.finish(); } catch (Throwable ignored) {}
    }
}
