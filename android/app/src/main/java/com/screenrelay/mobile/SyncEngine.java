package com.screenrelay.mobile;

import android.content.Context;

import java.io.FileNotFoundException;
import java.io.IOException;
import java.util.concurrent.Executors;
import java.util.concurrent.ExecutorService;
import java.util.function.BooleanSupplier;

final class SyncEngine {
    private static final ExecutorService WORKER = Executors.newSingleThreadExecutor();

    private SyncEngine() {}

    static void submit(Context context, BooleanSupplier cancelled, Runnable finished) {
        Context app = context.getApplicationContext();
        WORKER.execute(() -> {
            try {
                run(app, cancelled);
            } finally {
                finished.run();
            }
        });
    }

    static void retry(Context context) {
        Context app = context.getApplicationContext();
        WORKER.execute(() -> SyncStore.get(app).retry());
    }

    private static void run(Context context, BooleanSupplier stopped) {
        Settings settings = new Settings(context);
        int revision = settings.revision();
        BooleanSupplier cancelled = () -> stopped.getAsBoolean() || !settings.isEnabled()
                || settings.revision() != revision;
        if (cancelled.getAsBoolean()) {
            return;
        }
        if (!Settings.hasMediaAccess(context)) {
            settings.setStatus("需要允许访问所有照片和视频才能自动上传。");
            return;
        }
        Settings.Configuration configuration = settings.configuration();
        SyncStore store = SyncStore.get(context);
        try {
            new MediaSource(context, store, settings).scan(cancelled);
        } catch (RuntimeException inaccessible) {
            if (!cancelled.getAsBoolean()) {
                settings.setStatus("暂时无法读取系统相册，下次会重试。");
            }
            return;
        }

        for (int i = 0; i < 16 && !cancelled.getAsBoolean(); i++) {
            SyncStore.Upload item = store.next(System.currentTimeMillis());
            if (item == null) {
                if (store.counts().waiting() == 0 && store.counts().failed() == 0) {
                    settings.setStatus("正在等待新的截屏和录屏。");
                }
                return;
            }
            if (!send(context, settings, configuration, store, item, cancelled)) {
                return;
            }
        }
    }

    private static boolean send(Context context, Settings settings, Settings.Configuration configuration,
                                SyncStore store, SyncStore.Upload item, BooleanSupplier cancelled) {
        int code;
        try {
            code = UploadClient.upload(context.getContentResolver(), configuration, item, cancelled);
        } catch (FileNotFoundException removed) {
            if (!cancelled.getAsBoolean()) {
                if (item.attempts() >= 4) {
                    store.markFailed(item.id());
                    settings.setStatus("无法打开一项相册文件。");
                } else {
                    store.defer(item, retryDelay(item));
                }
            }
            return true;
        } catch (IOException network) {
            if (!cancelled.getAsBoolean()) {
                store.defer(item, retryDelay(item));
                settings.setStatus("暂时无法传输，已保留任务并将重试。");
            }
            return false;
        } catch (SecurityException accessRemoved) {
            if (!cancelled.getAsBoolean()) {
                settings.setStatus("请重新授权所有照片和视频。");
            }
            return false;
        }
        if (cancelled.getAsBoolean()) {
            return false;
        }
        if (code == 200 || code == 201) {
            store.markSent(item.id());
            settings.setStatus("已上传 " + item.name());
            return true;
        }
        if (code == 401 || code == 403) {
            store.defer(item, 120_000);
            settings.setStatus("电脑拒绝配对，请核对配对密钥。");
            return false;
        }
        if (code == 408 || code == 429 || code >= 500) {
            store.defer(item, retryDelay(item));
            settings.setStatus("电脑暂时无法接收，将自动重试。");
            return false;
        }
        store.markFailed(item.id());
        settings.setStatus(code == 413 ? "有文件超过电脑接收端的大小限制。"
                : "电脑拒绝了一项文件（HTTP " + code + "）。");
        return true;
    }

    private static long retryDelay(SyncStore.Upload upload) {
        return Math.min(30_000L << Math.min(upload.attempts(), 5), 15 * 60_000L);
    }
}
