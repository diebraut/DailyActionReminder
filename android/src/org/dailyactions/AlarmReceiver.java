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
import java.util.Calendar;

import android.app.NotificationChannel;
import android.app.NotificationManager;
import androidx.core.app.NotificationCompat;
import androidx.core.app.NotificationManagerCompat;

public class AlarmReceiver extends BroadcastReceiver {

    private static final String TAG = "AlarmReceiver";

    // Notification
    // IMPORTANT:
    // - Android NotificationChannel settings are sticky once created.
    // - We bump the channel id so existing installs immediately get a SILENT channel.
    private static final String CH_ID   = "dailyactions_reminder_silent_v2";
    private static final String CH_NAME = "DailyActionReminder";
    private static final String CH_DESC = "Aktionen/Erinnerungen";

    // Hard stop damit "kurz piepen" garantiert kurz bleibt
    private static final int BEEP_MAX_MS = 1200;     // 1.2s
    private static final int WAKELOCK_MS = 5000;     // 5s (nur damit CPU kurz wach bleibt)

    @Override
    public void onReceive(Context context, Intent intent) {
        final PendingResult pr = goAsync();

        int id = intent.getIntExtra(AlarmScheduler.EXTRA_REQUEST_ID,
                intent.getIntExtra(AlarmScheduler.EXTRA_NOTIF_ID, -1));

        String mode = intent.getStringExtra(AlarmScheduler.EXTRA_MODE);
        String fixed = intent.getStringExtra(AlarmScheduler.EXTRA_FIXED_TIME);
        try {
            long nowMs = System.currentTimeMillis();
            long plannedMs = -1;

            // für fixed="HH:MM" -> heute HH:MM:00.000
            if (fixed != null && fixed.contains(":")) {
                String[] p = fixed.trim().split(":");
                if (p.length >= 2) {
                    int hh = Integer.parseInt(p[0]);
                    int mm = Integer.parseInt(p[1]);

                    Calendar c = Calendar.getInstance();
                    c.setTimeInMillis(nowMs);
                    c.set(Calendar.HOUR_OF_DAY, hh);
                    c.set(Calendar.MINUTE, mm);
                    c.set(Calendar.SECOND, 0);
                    c.set(Calendar.MILLISECOND, 0);
                    plannedMs = c.getTimeInMillis();
                }
            }

            if (plannedMs > 0) {
                long diffMs = nowMs - plannedMs;
                Log.w(TAG, "checktime(fixed): planned=" + new java.util.Date(plannedMs)
                        + " now=" + new java.util.Date(nowMs)
                        + " diffMs=" + diffMs
                        + " diffSec=" + (diffMs / 1000.0));
            } else {
                Log.w(TAG, "checktime: cannot compute plannedMs from fixed='" + fixed + "'");
            }
        } catch (Throwable t) {
            Log.w(TAG, "checktime failed: " + t);
        }


        Log.w("AlarmReceiver",
              "ONRECEIVE id=" + id +
              " action=" + intent.getAction() +
              " mode=" + mode +
              " fixed=" + fixed +
              " now=" + new java.util.Date(System.currentTimeMillis()));
        Log.w("AlarmReceiver",
        "nowMs=" + System.currentTimeMillis() +
        " now=" + new java.util.Date(System.currentTimeMillis()));
        long plannedMs = intent.getLongExtra(AlarmScheduler.EXTRA_TRIGGER_AT_MILLIS, -1L);
        if (plannedMs > 0) {
            long nowMs = System.currentTimeMillis();
            long diffMs = nowMs - plannedMs;
            Log.w("AlarmReceiver checktime",
                  "plannedMs=" + plannedMs +
                  " planned=" + new java.util.Date(plannedMs) +
                  " nowMs=" + nowMs +
                  " diffMs=" + diffMs +
                  " diffSec=" + (diffMs/1000.0));
        } else {
            Log.w("AlarmReceiver  checktime", "plannedMs missing (EXTRA_TRIGGER_AT_MILLIS)");
        }

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
            final float volume01raw = intent.getFloatExtra(AlarmScheduler.EXTRA_VOLUME01, 1.0f);
            final float volume01 = Math.max(0f, Math.min(1f, volume01raw));

            Log.e(TAG, "### onReceive ###"
                    + " action=" + intent.getAction()
                    + " requestId=" + requestId
                    + " soundName=" + soundName
                    + " vol=" + volume01
                    + " sdk=" + Build.VERSION.SDK_INT
                    + " time=" + System.currentTimeMillis()
            );

            logAudioState(context);

            // ✅ Notification anzeigen
            showNotification(context.getApplicationContext(), intent, requestId);

            playShortBeep(context.getApplicationContext(), soundName, volume01, pr);
            // ✅ HIER: nächsten Intervall-Termin planen
            AlarmScheduler.rescheduleNextFromIntent(context.getApplicationContext(), intent);

        } catch (Throwable t) {
            Log.e(TAG, "onReceive failed", t);
            safeFinish(pr);
        }
    }


    // -------------------- NOTIFICATION --------------------
    private static void ensureNotificationChannel(Context ctx) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager nm = (NotificationManager) ctx.getSystemService(Context.NOTIFICATION_SERVICE);
            if (nm == null) return;

            NotificationChannel existing = nm.getNotificationChannel(CH_ID);
            if (existing != null) return;

            NotificationChannel ch = new NotificationChannel(
                    CH_ID,
                    CH_NAME,
                    NotificationManager.IMPORTANCE_HIGH
            );
            ch.setDescription(CH_DESC);

            // 🔇 Keep notifications silent (action sound is played by our own MediaPlayer)
            // Channel wins over NotificationCompat.Builder settings on Android 8+.
            ch.setSound(null, null);
            ch.enableVibration(false);
            ch.setVibrationPattern(null);
            ch.enableLights(false);
            ch.setShowBadge(false);

            nm.createNotificationChannel(ch);
            Log.w(TAG, "NotificationChannel created: " + CH_ID);
        }
    }

    private static void showNotification(Context ctx, Intent intent, int requestId) {
        try {
            ensureNotificationChannel(ctx);

            String title = intent.getStringExtra(AlarmScheduler.EXTRA_TITLE);
            String text  = intent.getStringExtra(AlarmScheduler.EXTRA_TEXT);

            if (title == null || title.trim().isEmpty()) title = "DailyActions";
            if (text == null) text = "";

            // Tap -> App öffnen
            Intent open = ctx.getPackageManager().getLaunchIntentForPackage(ctx.getPackageName());
            PendingIntent pi = null;
            if (open != null) {
                open.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TOP);
                int flags = PendingIntent.FLAG_UPDATE_CURRENT;
                if (Build.VERSION.SDK_INT >= 23) flags |= PendingIntent.FLAG_IMMUTABLE;
                pi = PendingIntent.getActivity(ctx, requestId, open, flags);
            }

            NotificationCompat.Builder b = new NotificationCompat.Builder(ctx, CH_ID)
                    .setSmallIcon(R.drawable.ic_stat_notify) // <-- Icon anlegen!
                    .setContentTitle(title)
                    .setContentText(text)
                    .setStyle(new NotificationCompat.BigTextStyle().bigText(text))
                    .setAutoCancel(true)
                    .setCategory(NotificationCompat.CATEGORY_REMINDER)
                    .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                    .setPriority(NotificationCompat.PRIORITY_HIGH)
                    // 🔇 extra safety (channel still wins on Android 8+)
                    .setSilent(true)
                    .setDefaults(0)
                    .setSound(null)
                    .setVibrate(null)
                    .setOnlyAlertOnce(true);

            if (pi != null) b.setContentIntent(pi);

            NotificationManagerCompat.from(ctx).notify(requestId, b.build());
        } catch (Throwable t) {
            Log.w(TAG, "showNotification failed: " + t);
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

            // 🔇 MUTE muss auch im Hintergrund respektiert werden
            volume01 = clamp01(volume01);
            if (volume01 <= 0.0f) {
                Log.w(TAG, "playShortBeep: MUTED (vol=0) -> skip soundName=" + soundName);
                releaseWakelock(wlRef[0]);
                safeFinish(pr);
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
                Log.e(TAG, "No usable raw sound found (soundName=" + soundName + "). " +
                        "Check: app/src/main/res/raw/bell.(mp3|wav|ogg)");
                releaseWakelock(wlRef[0]);
                safeFinish(pr);
                return;
            }


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
