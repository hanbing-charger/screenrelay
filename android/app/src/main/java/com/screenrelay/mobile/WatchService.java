package com.screenrelay.mobile;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.database.ContentObserver;
import android.net.Uri;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.provider.MediaStore;

public final class WatchService extends Service {
    private static final String CHANNEL = "screenrelay-upload";
    private static final int NOTIFICATION_ID = 8765;
    private static final String PAUSE = "com.screenrelay.mobile.PAUSE";
    private static final long POLL_INTERVAL_MS = 30_000L;
    private final Handler main = new Handler(Looper.getMainLooper());
    private final Runnable tick = this::sync;
    private final ContentObserver observer = new ContentObserver(main) {
        @Override
        public void onChange(boolean selfChange, Uri uri) {
            requestSync(1_200L);
        }
    };
    private volatile boolean destroyed;
    private boolean observing;
    private boolean syncing;
    private boolean changedWhileSyncing;
    private static volatile boolean running;

    static boolean isRunning() {
        return running;
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Settings settings = new Settings(this);
        if (intent != null && PAUSE.equals(intent.getAction())) {
            settings.disable();
            SyncJob.cancel(this);
            stopForeground(STOP_FOREGROUND_REMOVE);
            stopSelf();
            return START_NOT_STICKY;
        }
        if (!settings.isEnabled()) {
            stopSelf();
            return START_NOT_STICKY;
        }

        NotificationManager notifications = getSystemService(NotificationManager.class);
        notifications.createNotificationChannel(new NotificationChannel(
                CHANNEL, "自动上传", NotificationManager.IMPORTANCE_LOW));
        startForeground(NOTIFICATION_ID, notification());
        running = true;
        if (!observing) {
            getContentResolver().registerContentObserver(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                    true, observer);
            getContentResolver().registerContentObserver(MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                    true, observer);
            observing = true;
        }
        requestSync(0);
        return START_STICKY;
    }

    private Notification notification() {
        PendingIntent open = PendingIntent.getActivity(this, 0, new Intent(this, MainActivity.class),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        PendingIntent pause = PendingIntent.getService(this, 1,
                new Intent(this, WatchService.class).setAction(PAUSE),
                PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
        return new Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_upload)
                .setContentTitle("截屏快传")
                .setContentText("自动上传新截屏和录屏")
                .setCategory(Notification.CATEGORY_SERVICE)
                .setContentIntent(open)
                .setOngoing(true)
                .addAction(new Notification.Action.Builder(null, "暂停", pause).build())
                .build();
    }

    private void requestSync(long delay) {
        if (destroyed) {
            return;
        }
        if (syncing) {
            changedWhileSyncing = true;
        } else {
            main.removeCallbacks(tick);
            main.postDelayed(tick, delay);
        }
    }

    private void sync() {
        syncing = true;
        SyncEngine.submit(this, () -> destroyed, moreReady -> main.post(() -> {
            syncing = false;
            long delay = changedWhileSyncing || moreReady ? 0 : POLL_INTERVAL_MS;
            changedWhileSyncing = false;
            requestSync(delay);
        }));
    }

    @Override
    public void onTimeout(int startId, int foregroundServiceType) {
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    @Override
    public void onDestroy() {
        destroyed = true;
        running = false;
        main.removeCallbacksAndMessages(null);
        if (observing) {
            getContentResolver().unregisterContentObserver(observer);
        }
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
