package com.screenrelay.mobile;

import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Locale;
import java.util.function.BooleanSupplier;
import java.util.regex.Pattern;

final class MediaSource {
    private static final String[] FIELDS = {
            MediaStore.MediaColumns._ID, MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.RELATIVE_PATH, MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.OWNER_PACKAGE_NAME
    };

    private static final Pattern SEPARATORS = Pattern.compile("[\\s_.-]+");
    private static final Pattern INVALID_FILENAME = Pattern.compile("[\\p{Cntrl}/\\\\]");
    private static final Pattern AOSP_RECORDING_NAME = Pattern.compile("screen-\\d{8}-\\d{6}\\.mp4");

    private final Context context;
    private final SyncStore store;
    private final Settings settings;

    MediaSource(Context context, SyncStore store, Settings settings) {
        this.context = context;
        this.store = store;
        this.settings = settings;
    }

    void scan(BooleanSupplier cancelled) {
        for (String volume : MediaStore.getExternalVolumeNames(context)) {
            if (cancelled.getAsBoolean()) {
                return;
            }
            long generation = Build.VERSION.SDK_INT >= 30
                    ? MediaStore.getGeneration(context, volume) : -1;
            String version = Build.VERSION.SDK_INT >= 30 ? MediaStore.getVersion(context, volume) : "";
            scanCollection(MediaStore.Images.Media.getContentUri(volume), false, version, generation, cancelled);
            scanCollection(MediaStore.Video.Media.getContentUri(volume), true, version, generation, cancelled);
        }
    }

    private void scanCollection(Uri collection, boolean video, String version, long generation,
                                BooleanSupplier cancelled) {
        if (cancelled.getAsBoolean()) {
            return;
        }
        long baseline = settings.firstEnabledAt();
        if (baseline < 0) {
            return;
        }

        // Android 10 lacks MediaStore generation counters and uses the initial capture date directly.
        String selection = MediaStore.MediaColumns.DATE_ADDED + ">=? AND "
                + MediaStore.MediaColumns.IS_PENDING + "=0 AND " + MediaStore.MediaColumns.SIZE + ">0";
        String[] arguments = {Long.toString(baseline)};
        if (Build.VERSION.SDK_INT >= 30) {
            SyncStore.Checkpoint checkpoint = store.checkpoint(collection.toString());
            long previous = version.equals(checkpoint.version()) && generation >= checkpoint.generation()
                    ? checkpoint.generation() : 0;
            if (previous == generation && version.equals(checkpoint.version())) {
                return;
            }
            selection += " AND " + MediaStore.MediaColumns.IS_TRASHED + "=0 AND "
                    + MediaStore.MediaColumns.GENERATION_MODIFIED + ">? AND "
                    + MediaStore.MediaColumns.GENERATION_MODIFIED + "<=?";
            arguments = new String[]{Long.toString(baseline), Long.toString(previous), Long.toString(generation)};
        }

        ContentResolver resolver = context.getContentResolver();
        try (Cursor cursor = resolver.query(collection, FIELDS, selection, arguments, null)) {
            if (cursor == null) {
                throw new IllegalStateException("MediaStore query did not return a cursor");
            }
            SQLiteDatabase database = store.getWritableDatabase();
            database.beginTransactionNonExclusive();
            try {
                String installationId = settings.installationId();
                String appPackage = context.getPackageName();
                while (cursor.moveToNext()) {
                    if (cancelled.getAsBoolean()) {
                        return;
                    }
                    if (appPackage.equals(cursor.getString(6))) {
                        continue;
                    }
                    String name = cursor.getString(1);
                    String kind = classify(video, cursor.getString(2), name);
                    if (kind == null) {
                        continue;
                    }
                    long added = cursor.getLong(5);
                    Uri uri = ContentUris.withAppendedId(collection, cursor.getLong(0));
                    String uploadId = identifier(installationId, uri.toString(), added);
                    String safeName = INVALID_FILENAME.matcher(name).replaceAll("_");
                    store.enqueue(database, new SyncStore.Upload(uploadId, uri, safeName, kind,
                            contentType(cursor.getString(3), video), cursor.getLong(4), added, 0));
                }
                if (Build.VERSION.SDK_INT >= 30) {
                    store.saveCheckpoint(database, collection.toString(), version, generation);
                }
                database.setTransactionSuccessful();
            } finally {
                database.endTransaction();
            }
        }
    }

    static String classify(boolean video, String path, String name) {
        if (name == null || name.isEmpty()) {
            return null;
        }
        String filename = normalize(name);
        if (video && (isScreenRecording(filename) || isScreenshot(filename)
                || AOSP_RECORDING_NAME.matcher(name.toLowerCase(Locale.ROOT)).matches())) {
            return "screen-recording";
        }
        if (!video && isScreenshot(filename)) {
            return "screenshot";
        }
        if (path == null) {
            return null;
        }
        for (String component : path.split("/")) {
            String directory = normalize(component);
            if (video && (isScreenRecording(directory) || isScreenshot(directory))) {
                return "screen-recording";
            }
            if (!video && isScreenshot(directory)) {
                return "screenshot";
            }
        }
        return null;
    }

    private static String normalize(String field) {
        return SEPARATORS.matcher(field.toLowerCase(Locale.ROOT)).replaceAll("");
    }

    private static boolean isScreenshot(String field) {
        return field.startsWith("screenshot") || field.startsWith("screencapture")
                || field.startsWith("截屏") || field.startsWith("截图")
                || field.startsWith("螢幕截圖") || field.startsWith("屏幕截图");
    }

    private static boolean isScreenRecording(String field) {
        return field.startsWith("screenrecord") || field.startsWith("screenrec")
                || field.startsWith("录屏") || field.startsWith("錄屏")
                || field.startsWith("屏幕录制") || field.startsWith("螢幕錄製");
    }

    private static String contentType(String mediaType, boolean video) {
        if (mediaType != null && mediaType.matches("[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+")) {
            return mediaType;
        }
        return video ? "video/mp4" : "image/png";
    }

    private static String identifier(String installationId, String uri, long added) {
        try {
            byte[] bytes = (installationId + "\n" + uri + "\n" + added).getBytes(StandardCharsets.UTF_8);
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(bytes);
            StringBuilder hex = new StringBuilder(digest.length * 2);
            for (byte value : digest) {
                hex.append(Character.forDigit((value & 0xff) >>> 4, 16));
                hex.append(Character.forDigit(value & 0xf, 16));
            }
            return hex.toString();
        } catch (NoSuchAlgorithmException unavailable) {
            throw new IllegalStateException(unavailable);
        }
    }
}
