package com.screenrelay.mobile;

import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.net.Uri;
import android.os.Environment;
import android.os.ParcelFileDescriptor;
import android.os.SystemClock;
import android.provider.MediaStore;

import java.io.IOException;
import java.nio.channels.FileChannel;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

final class IncomingDownloads {
    private static final long[] RETRY_DELAYS_MS = {1_000L, 3_000L, 6_000L};
    private static IncomingDownloads instance;

    record State(String message, long received, long total, boolean running, boolean resumable) {}
    private record Pending(Uri uri, DownloadClient.Metadata metadata) {}
    private record Item(String name, boolean pending) {}

    static synchronized IncomingDownloads get(Context context) {
        if (instance == null) {
            instance = new IncomingDownloads(context.getApplicationContext());
        }
        return instance;
    }

    private final ContentResolver resolver;
    private final SharedPreferences preferences;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private volatile State state;
    private boolean restored;

    private IncomingDownloads(Context context) {
        resolver = context.getContentResolver();
        preferences = context.getSharedPreferences("incoming-download", Context.MODE_PRIVATE);
        state = savedRequest() == null ? new State("", 0, -1, false, false)
                : new State("可继续接收上次的文件。", 0, -1, false, true);
    }

    State state() {
        return state;
    }

    synchronized void restoreOnce() {
        if (!restored) {
            restored = true;
            resume();
        }
    }

    synchronized void start(DownloadClient.Request request) {
        if (state.running() || state.resumable()) {
            return;
        }
        state = new State("正在连接电脑…", 0, -1, true, false);
        worker.execute(() -> {
            if (!preferences.edit().putString("origin", request.origin())
                    .putString("code", request.code()).commit()) {
                preferences.edit().clear().apply();
                state = new State("手机无法保存接收任务。请检查存储空间后重新扫码。", 0, -1, false, false);
                return;
            }
            receiveWithRetries(request);
        });
    }

    synchronized void resume() {
        if (state.running() || !state.resumable()) {
            return;
        }
        DownloadClient.Request request = savedRequest();
        if (request != null) {
            state = new State("正在继续接收…", state.received(), state.total(), true, false);
            worker.execute(() -> receiveWithRetries(request));
        }
    }

    synchronized void discard() {
        if (state.running() || !state.resumable()) {
            return;
        }
        state = new State("正在清理未完成的文件…", 0, -1, true, false);
        worker.execute(() -> forget("已放弃本次接收。"));
    }

    private void receiveWithRetries(DownloadClient.Request request) {
        for (int attempt = 0; ; attempt++) {
            try {
                receive(request);
                return;
            } catch (DownloadClient.Rejected rejected) {
                forget(rejected.getMessage());
                return;
            } catch (IOException | RuntimeException failure) {
                if (attempt == RETRY_DELAYS_MS.length || Thread.currentThread().isInterrupted()) {
                    break;
                }
                state = new State("接收中断，正在自动重试…", state.received(), state.total(), true, false);
                try {
                    Thread.sleep(RETRY_DELAYS_MS[attempt]);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
        }
        state = new State("接收已暂停。请检查 Wi-Fi、电脑接收端及手机存储空间，然后继续接收。",
                state.received(), state.total(), false, true);
    }

    private void receive(DownloadClient.Request request) throws IOException {
        Pending pending = savedPending();
        Item item = pending == null ? null : find(pending.uri());
        if (item == null) {
            pending = createPending(DownloadClient.inspect(request));
            item = find(pending.uri());
            if (item == null) {
                throw new IOException("Downloads entry is unavailable");
            }
        }
        if (!item.pending()) {
            complete(item.name(), pending.metadata().length());
            return;
        }

        Uri uri = pending.uri();
        DownloadClient.Metadata metadata = pending.metadata();
        ParcelFileDescriptor descriptor = resolver.openFileDescriptor(uri, "rw");
        if (descriptor == null) {
            throw new IOException("Downloads output is unavailable");
        }
        try (ParcelFileDescriptor.AutoCloseOutputStream output =
                     new ParcelFileDescriptor.AutoCloseOutputStream(descriptor)) {
            FileChannel channel = output.getChannel();
            long offset = channel.size();
            if (offset > metadata.length()) {
                channel.truncate(0);
                offset = 0;
            }
            channel.position(offset);
            String message = "正在接收 " + item.name();
            state = new State(message, offset, metadata.length(), true, false);
            long[] lastProgressAt = {0L};
            DownloadClient.transfer(request, metadata, offset, output, received -> {
                long now = SystemClock.elapsedRealtime();
                if (received == metadata.length() || now - lastProgressAt[0] >= 250L) {
                    lastProgressAt[0] = now;
                    state = new State(message, received, metadata.length(), true, false);
                }
            }, Thread.currentThread()::isInterrupted);
            if (channel.size() != metadata.length()) {
                throw new IOException("Unexpected Downloads file length");
            }
            output.getFD().sync();
        }

        ContentValues complete = new ContentValues();
        complete.put(MediaStore.MediaColumns.IS_PENDING, 0);
        if (resolver.update(uri, complete, null, null) != 1) {
            throw new IOException("Could not publish Downloads entry");
        }
        Item published = find(uri);
        if (published == null || published.pending()) {
            throw new IOException("Published Downloads entry is unavailable");
        }
        complete(published.name(), metadata.length());
    }

    private Pending createPending(DownloadClient.Metadata metadata) throws IOException {
        ContentValues values = new ContentValues();
        values.put(MediaStore.MediaColumns.DISPLAY_NAME, safeFilename(metadata.filename()));
        values.put(MediaStore.MediaColumns.MIME_TYPE, metadata.mime());
        values.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS + "/");
        values.put(MediaStore.MediaColumns.IS_PENDING, 1);
        // A new MediaStore row allocates a unique path without overwriting a Downloads file.
        Uri collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY);
        Uri uri = resolver.insert(collection, values);
        if (uri == null) {
            throw new IOException("Could not allocate Downloads entry");
        }
        if (!preferences.edit().putString("uri", uri.toString())
                .putString("filename", metadata.filename()).putString("mime", metadata.mime())
                .putLong("length", metadata.length()).putString("etag", metadata.etag()).commit()) {
            resolver.delete(uri, null, null);
            throw new IOException("Could not save the Downloads entry");
        }
        return new Pending(uri, metadata);
    }

    private Item find(Uri uri) throws IOException {
        try (Cursor result = resolver.query(uri, new String[]{MediaStore.MediaColumns.DISPLAY_NAME,
                MediaStore.MediaColumns.IS_PENDING}, null, null, null)) {
            if (result == null) {
                throw new IOException("Downloads query is unavailable");
            }
            return result.moveToFirst() ? new Item(result.getString(0), result.getInt(1) != 0) : null;
        }
    }

    private DownloadClient.Request savedRequest() {
        String origin = preferences.getString("origin", "");
        String code = preferences.getString("code", "");
        return origin.isEmpty() || code.isEmpty() ? null : new DownloadClient.Request(origin, code);
    }

    private Pending savedPending() {
        String uri = preferences.getString("uri", "");
        if (uri.isEmpty()) {
            return null;
        }
        return new Pending(Uri.parse(uri), new DownloadClient.Metadata(
                preferences.getString("filename", ""), preferences.getString("mime", "application/octet-stream"),
                preferences.getLong("length", -1), preferences.getString("etag", "")));
    }

    private void complete(String name, long length) {
        preferences.edit().clear().apply();
        state = new State("已保存到下载目录\n" + name, length, length, false, false);
    }

    private void forget(String message) {
        try {
            Pending pending = savedPending();
            if (pending != null) {
                Item item = find(pending.uri());
                if (item != null && item.pending() && resolver.delete(pending.uri(), null, null) != 1) {
                    throw new IOException("Could not remove pending Downloads entry");
                }
            }
            preferences.edit().clear().apply();
            state = new State(message, 0, -1, false, false);
        } catch (IOException | RuntimeException cleanupFailed) {
            state = new State(message + "\n暂时无法清理未完成的文件，请重试。", 0, -1, false, true);
        }
    }

    private static String safeFilename(String name) {
        String filename = name.replaceAll("[\\p{Cntrl}/\\\\:*?\"<>|]", "_").trim();
        if (filename.isEmpty() || ".".equals(filename) || "..".equals(filename)) {
            return "收到的文件";
        }
        return filename.startsWith(".") ? "文件" + filename : filename;
    }
}
