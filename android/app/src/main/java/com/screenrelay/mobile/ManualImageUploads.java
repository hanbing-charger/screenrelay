package com.screenrelay.mobile;

import android.content.ContentResolver;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.BufferedInputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.util.Arrays;
import java.util.Comparator;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

final class ManualImageUploads {
    private static final long[] RETRY_MS = {1_000L, 3_000L};
    private static final int BUFFER_BYTES = 64 * 1024;
    private static ManualImageUploads instance;

    record State(String message, boolean busy, int pending) {}

    static synchronized ManualImageUploads get(Context context) {
        if (instance == null) {
            instance = new ManualImageUploads(context.getApplicationContext());
        }
        return instance;
    }

    private final File directory;
    private final ContentResolver resolver;
    private final ExecutorService worker = Executors.newSingleThreadExecutor();
    private volatile State state;

    private ManualImageUploads(Context context) {
        directory = new File(context.getFilesDir(), "selected-photo-uploads");
        resolver = context.getContentResolver();
        int pending = pending().length;
        state = new State(pending == 0 ? "" : "上次待传的图片已保留，可以继续上传。", false, pending);
        worker.execute(() -> {
            File[] unfinishedCopies = directory.listFiles(file -> file.getName().startsWith(".copy-")
                    || file.getName().startsWith(".done-"));
            if (unfinishedCopies != null) {
                for (File copy : unfinishedCopies) {
                    deleteStaging(copy);
                }
            }
        });
    }

    State state() {
        return state;
    }

    synchronized void start(List<Uri> selected, Settings.Configuration configuration) {
        if (state.busy() || state.pending() != 0 || selected.isEmpty()) {
            return;
        }
        state = new State("正在读取所选图片…", true, 0);
        worker.execute(() -> {
            int unreadable = 0;
            String selectionError = "";
            for (int i = 0; i < selected.size(); i++) {
                state = new State("正在读取图片 " + (i + 1) + " / " + selected.size(), true, 0);
                try {
                    stage(selected.get(i), configuration.origin());
                } catch (IOException | JSONException | RuntimeException failure) {
                    unreadable++;
                    selectionError = failure instanceof UnsupportedPhoto ? failure.getMessage()
                            : "请检查图片来源和手机存储空间，再重新选择。";
                }
            }
            String result = unreadable == 0 ? "" : "有 " + unreadable + " 张图片未能读取。" + selectionError;
            send(configuration, result);
        });
    }

    synchronized void resume(Settings.Configuration configuration) {
        if (state.busy() || state.pending() == 0) {
            return;
        }
        state = new State("正在连接电脑…", true, state.pending());
        worker.execute(() -> send(configuration, ""));
    }

    synchronized void discard() {
        if (state.busy() || state.pending() == 0) {
            return;
        }
        state = new State("正在清理待传图片…", true, state.pending());
        worker.execute(() -> {
            for (File photo : pending()) {
                try {
                    remove(photo);
                } catch (IOException failure) {
                    break;
                }
            }
            int count = pending().length;
            state = new State(count == 0 ? "待传图片已清除。" : "暂时无法清除部分图片，请重试。", false, count);
        });
    }

    private void stage(Uri uri, String origin) throws IOException, JSONException {
        Files.createDirectories(directory.toPath());
        File staging = Files.createTempDirectory(directory.toPath(), ".copy-").toFile();
        try {
            String filename = displayName(uri);
            String mime = resolver.getType(uri);
            InputStream original = resolver.openInputStream(uri);
            if (original == null) {
                throw new IOException("Selected image is unavailable");
            }
            ManualPhoto image;
            try (BufferedInputStream source = new BufferedInputStream(original);
                 FileOutputStream target = new FileOutputStream(new File(staging, "body"))) {
                source.mark(32);
                byte[] prefix = new byte[16];
                int count = 0;
                while (count < prefix.length) {
                    int read = source.read(prefix, count, prefix.length - count);
                    if (read <= 0) {
                        break;
                    }
                    count += read;
                }
                if (count == 0) {
                    throw new IOException("Selected image is empty");
                }
                source.reset();
                try {
                    image = ManualPhoto.identify(filename, mime, Arrays.copyOf(prefix, count));
                } catch (IllegalArgumentException unsupported) {
                    throw new UnsupportedPhoto(unsupported.getMessage());
                }
                byte[] buffer = new byte[BUFFER_BYTES];
                while ((count = source.read(buffer)) != -1) {
                    target.write(buffer, 0, count);
                }
                target.getFD().sync();
            }

            JSONObject details = new JSONObject();
            details.put("filename", image.filename());
            details.put("mime", image.mime());
            details.put("origin", origin);
            try (FileOutputStream metadata = new FileOutputStream(new File(staging, "details"))) {
                metadata.write(details.toString().getBytes(StandardCharsets.UTF_8));
                metadata.getFD().sync();
            }
            File queued = new File(directory, "photo-" + UUID.randomUUID());
            Files.move(staging.toPath(), queued.toPath(), StandardCopyOption.ATOMIC_MOVE);
        } finally {
            deleteStaging(staging);
        }
    }

    private String displayName(Uri uri) {
        try (Cursor cursor = resolver.query(uri, new String[]{OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            return cursor != null && cursor.moveToFirst() ? cursor.getString(0) : null;
        }
    }

    private void send(Settings.Configuration configuration, String selectionResult) {
        File[] queued = pending();
        int sent = 0;
        int unavailable = 0;
        String error = "";
        for (int i = 0; i < queued.length; i++) {
            File folder = queued[i];
            state = new State("正在上传图片 " + (i + 1) + " / " + queued.length, true, queued.length - sent);
            try {
                JSONObject details = new JSONObject(new String(Files.readAllBytes(new File(folder, "details").toPath()),
                        StandardCharsets.UTF_8));
                if (!configuration.origin().equals(details.getString("origin"))) {
                    error = "待传图片属于另一台电脑，请切换回原来的配对，或清除待传图片。";
                    break;
                }
                int status = uploadWithRetry(configuration, folder, details.getString("filename"), details.getString("mime"));
                if (status == 200 || status == 201) {
                    remove(folder);
                    sent++;
                    continue;
                }
                if (status == 413) {
                    error = "有图片超过电脑接收端的大小限制。";
                    continue;
                }
                if (status == 401 || status == 403) {
                    error = "电脑拒绝配对，请重新配对后继续上传。";
                } else if (status == 400 || status == 404 || status == 405 || status == 415) {
                    error = "电脑未接收所选图片，请将接收端升级到 v0.7.0 或更新版本后继续上传。";
                } else if (status == 408 || status == 429 || status >= 500) {
                    error = "电脑暂时无法接收图片，请稍后继续上传。";
                } else {
                    error = "电脑未接收图片（HTTP " + status + "）。";
                }
                break;
            } catch (JSONException malformed) {
                unavailable++;
                try {
                    remove(folder);
                } catch (IOException failure) {
                    error = "无法清理损坏的待传图片，请重试。";
                    break;
                }
            } catch (IOException | RuntimeException failure) {
                error = "传输未完成。请确认电脑接收端正在运行、手机和电脑连接同一 Wi-Fi，然后继续上传。";
                break;
            }
        }
        String result = sent == 0 ? "" : "已上传 " + sent + " 张图片。";
        if (unavailable > 0) {
            result += "有 " + unavailable + " 张暂存图片无法读取，请重新选择。";
        }
        state = new State(result + selectionResult + error, false, pending().length);
    }

    private int uploadWithRetry(Settings.Configuration configuration, File folder, String filename, String mime)
            throws IOException {
        for (int attempt = 0; ; attempt++) {
            try {
                int status = UploadClient.uploadPhoto(configuration, new File(folder, "body"),
                        folder.getName(), filename, mime);
                if ((status != 408 && status != 429 && status < 500) || attempt == RETRY_MS.length) {
                    return status;
                }
            } catch (IOException network) {
                if (attempt == RETRY_MS.length) {
                    throw network;
                }
            }
            try {
                Thread.sleep(RETRY_MS[attempt]);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw new IOException("Upload interrupted", interrupted);
            }
        }
    }

    private File[] pending() {
        File[] files = directory.listFiles(file -> file.isDirectory() && file.getName().startsWith("photo-"));
        if (files == null) {
            return new File[0];
        }
        Arrays.sort(files, Comparator.comparingLong(File::lastModified).thenComparing(File::getName));
        return files;
    }

    private void remove(File item) throws IOException {
        // Dequeue atomically before deleting the body so a partial cleanup remains harmless.
        File completed = new File(directory, ".done-" + item.getName());
        Files.move(item.toPath(), completed.toPath(), StandardCopyOption.ATOMIC_MOVE);
        deleteStaging(completed);
    }

    private static void deleteStaging(File folder) {
        new File(folder, "body").delete();
        new File(folder, "details").delete();
        folder.delete();
    }

    private static final class UnsupportedPhoto extends IOException {
        UnsupportedPhoto(String message) {
            super(message);
        }
    }
}
