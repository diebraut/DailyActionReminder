package org.dailyactions;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.Service;
import android.content.Intent;
import android.content.res.AssetFileDescriptor;
import android.media.AudioAttributes;
import android.media.AudioManager;
import android.media.MediaPlayer;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.util.Log;

import androidx.core.app.NotificationCompat;

public class ReminderSoundService extends Service {

    private static final String TAG = "ReminderSoundService";
    private static final String CHANNEL_ID = "daily_action_reminder_channel";

    private final Handler handler = new Handler(Looper.getMainLooper());
    private MediaPlayer mediaPlayer;

    private String volumesSnapshot() {
        try {
            AudioManager am = (AudioManager) getSystemService(AUDIO_SERVICE);
            if (am == null) return "AudioManager=null";

            int music = am.getStreamVolume(AudioManager.STREAM_MUSIC);
            int musicMax = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC);

            int alarm = am.getStreamVolume(AudioManager.STREAM_ALARM);
            int alarmMax = am.getStreamMaxVolume(AudioManager.STREAM_ALARM);

            int ringMode = am.getRingerMode();

            return "STREAM_MUSIC=" + music + "/" + musicMax
                    + " STREAM_ALARM=" + alarm + "/" + alarmMax
                    + " ringerMode=" + ringMode;
        } catch (Throwable t) {
            return "volSnapshot=?";
        }
    }

    @Override
    public void onCreate() {
        super.onCreate();
        createNotificationChannel();
        Log.i(TAG, "onCreate " + volumesSnapshot());
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null) {
            Log.w(TAG, "onStartCommand intent=null -> stopSelf");
            stopSelf();
            return START_NOT_STICKY;
        }

        String soundName = intent.getStringExtra(AlarmScheduler.EXTRA_SOUND_NAME);
        if (soundName == null || soundName.trim().isEmpty()) soundName = "bell";

        int notifId = intent.getIntExtra(AlarmScheduler.EXTRA_NOTIF_ID, 1001);
        int requestId = intent.getIntExtra(AlarmScheduler.EXTRA_REQUEST_ID, notifId);

        String title = intent.getStringExtra(AlarmScheduler.EXTRA_TITLE);
        String text = intent.getStringExtra(AlarmScheduler.EXTRA_TEXT);

        float volume01 = intent.getFloatExtra(AlarmScheduler.EXTRA_VOLUME01, 1.0f);
        float v = Math.max(0f, Math.min(1f, volume01));

        Log.i(TAG, "onStartCommand id=" + requestId
                + " sound=" + soundName
                + " vol=" + v
                + " flags=" + flags
                + " startId=" + startId
                + " " + volumesSnapshot()
        );

        Notification notification = buildNotification(
                title != null ? title : "DailyActionReminder",
                text != null ? text : "Reminder sound playing…"
        );

        try {
            startForeground(notifId, notification);
            Log.i(TAG, "startForeground ok notifId=" + notifId);
        } catch (Throwable t) {
            Log.e(TAG, "startForeground failed", t);
        }

        startPlayback(soundName, v);

        return START_NOT_STICKY;
    }

    private void startPlayback(String soundName, float volume01) {
        stopPlayback();

        int resId = getResources().getIdentifier(soundName, "raw", getPackageName());
        if (resId == 0) {
            Log.w(TAG, "sound '" + soundName + "' not found in raw/. Using bell");
            resId = getResources().getIdentifier("bell", "raw", getPackageName());
        }
        if (resId == 0) {
            Log.e(TAG, "No fallback sound 'bell' found. stopSelf()");
            stopSelf();
            return;
        }

        try {
            AssetFileDescriptor afd = getResources().openRawResourceFd(resId);
            if (afd == null) {
                Log.e(TAG, "openRawResourceFd returned null");
                stopSelf();
                return;
            }

            mediaPlayer = new MediaPlayer();

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
                AudioAttributes aa = new AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build();
                mediaPlayer.setAudioAttributes(aa);
            }

            mediaPlayer.setDataSource(afd.getFileDescriptor(), afd.getStartOffset(), afd.getLength());
            afd.close();

            mediaPlayer.setVolume(volume01, volume01);

            mediaPlayer.setOnPreparedListener(mp -> {
                Log.i(TAG, "MediaPlayer prepared. start() vol=" + volume01 + " " + volumesSnapshot());
                mp.start();
            });

            mediaPlayer.setOnCompletionListener(mp -> {
                Log.i(TAG, "Playback completed. stopSelf()");
                stopPlayback();
                stopSelf();
            });

            mediaPlayer.setOnErrorListener((mp, what, extra) -> {
                Log.e(TAG, "MediaPlayer error what=" + what + " extra=" + extra);
                stopPlayback();
                stopSelf();
                return true;
            });

            mediaPlayer.prepareAsync();
            Log.i(TAG, "prepareAsync issued for resId=" + resId);

        } catch (Throwable t) {
            Log.e(TAG, "startPlayback failed", t);
            stopPlayback();
            stopSelf();
        }
    }

    private void stopPlayback() {
        try {
            if (mediaPlayer != null) {
                mediaPlayer.stop();
            }
        } catch (Throwable ignored) {}
        try {
            if (mediaPlayer != null) {
                mediaPlayer.release();
            }
        } catch (Throwable ignored) {}
        mediaPlayer = null;
    }

    @Override
    public void onDestroy() {
        Log.i(TAG, "onDestroy");
        stopPlayback();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) { return null; }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID,
                    "Daily Action Reminder",
                    NotificationManager.IMPORTANCE_LOW
            );
            NotificationManager nm = (NotificationManager) getSystemService(NOTIFICATION_SERVICE);
            if (nm != null) nm.createNotificationChannel(channel);
        }
    }

    private Notification buildNotification(String title, String text) {
        return new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
                .setOngoing(true)
                .build();
    }
}
