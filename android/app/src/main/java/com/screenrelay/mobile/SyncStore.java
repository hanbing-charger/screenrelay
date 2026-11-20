package com.screenrelay.mobile;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.net.Uri;

final class SyncStore extends SQLiteOpenHelper {
    private static SyncStore instance;

    static synchronized SyncStore get(Context context) {
        if (instance == null) {
            instance = new SyncStore(context.getApplicationContext());
        }
        return instance;
    }

    private SyncStore(Context context) {
        super(context, "screenrelay.db", null, 1);
        setWriteAheadLoggingEnabled(true);
    }

    @Override
    public void onCreate(SQLiteDatabase database) {
        database.execSQL(
                "CREATE TABLE uploads (id TEXT PRIMARY KEY, uri TEXT NOT NULL, name TEXT NOT NULL, "
                + "kind TEXT NOT NULL, mime TEXT NOT NULL, size INTEGER NOT NULL, "
                + "added INTEGER NOT NULL, state INTEGER NOT NULL DEFAULT 0, "
                + "attempts INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0)");
        database.execSQL("CREATE INDEX uploads_ready ON uploads (state, next_attempt, added)");
        database.execSQL(
                "CREATE TABLE scan_checkpoints (collection TEXT PRIMARY KEY, version TEXT NOT NULL, "
                + "generation INTEGER NOT NULL)");
    }

    @Override
    public void onUpgrade(SQLiteDatabase database, int oldVersion, int newVersion) {
        throw new IllegalStateException("Unsupported database migration");
    }

    record Upload(String id, Uri uri, String name, String kind, String mime,
                  long size, long added, int attempts) {}

    record Checkpoint(String version, long generation) {}

    record Counts(int waiting, int uploaded, int failed) {}

    Checkpoint checkpoint(String collection) {
        try (Cursor cursor = getReadableDatabase().query("scan_checkpoints",
                new String[]{"version", "generation"}, "collection=?", new String[]{collection},
                null, null, null)) {
            return cursor.moveToFirst()
                    ? new Checkpoint(cursor.getString(0), cursor.getLong(1))
                    : new Checkpoint("", 0);
        }
    }

    void saveCheckpoint(SQLiteDatabase database, String collection, String version, long generation) {
        ContentValues values = new ContentValues();
        values.put("collection", collection);
        values.put("version", version);
        values.put("generation", generation);
        database.insertWithOnConflict("scan_checkpoints", null, values, SQLiteDatabase.CONFLICT_REPLACE);
    }

    void enqueue(SQLiteDatabase database, Upload upload) {
        ContentValues metadata = new ContentValues();
        metadata.put("uri", upload.uri().toString());
        metadata.put("name", upload.name());
        metadata.put("kind", upload.kind());
        metadata.put("mime", upload.mime());
        metadata.put("size", upload.size());
        metadata.put("added", upload.added());
        // Update unfinished items if MediaStore is still finalizing the asset's metadata.
        int updated = database.update("uploads", metadata,
                "id=? AND state=0 AND (uri<>? OR name<>? OR mime<>? OR size<>?)",
                new String[]{upload.id(), upload.uri().toString(), upload.name(), upload.mime(),
                        Long.toString(upload.size())});
        if (updated == 0) {
            metadata.put("id", upload.id());
            database.insertWithOnConflict("uploads", null, metadata, SQLiteDatabase.CONFLICT_IGNORE);
        }
    }

    Upload next(long now) {
        try (Cursor cursor = getReadableDatabase().query("uploads",
                new String[]{"id", "uri", "name", "kind", "mime", "size", "added", "attempts"},
                "state=0 AND next_attempt<=?", new String[]{Long.toString(now)},
                null, null, "added, id", "1")) {
            if (!cursor.moveToFirst()) {
                return null;
            }
            return new Upload(cursor.getString(0), Uri.parse(cursor.getString(1)), cursor.getString(2),
                    cursor.getString(3), cursor.getString(4), cursor.getLong(5),
                    cursor.getLong(6), cursor.getInt(7));
        }
    }

    void markSent(String id) {
        changeState(id, 1);
    }

    void markFailed(String id) {
        changeState(id, 2);
    }

    private void changeState(String id, int state) {
        ContentValues values = new ContentValues();
        values.put("state", state);
        getWritableDatabase().update("uploads", values, "id=?", new String[]{id});
    }

    void defer(Upload upload, long delayMs) {
        ContentValues values = new ContentValues();
        values.put("attempts", upload.attempts() + 1);
        values.put("next_attempt", System.currentTimeMillis() + delayMs);
        getWritableDatabase().update("uploads", values, "id=?", new String[]{upload.id()});
    }

    void retry() {
        ContentValues values = new ContentValues();
        values.put("state", 0);
        values.put("attempts", 0);
        values.put("next_attempt", 0);
        getWritableDatabase().update("uploads", values, "state<>1", null);
    }

    Counts counts() {
        int[] counts = new int[3];
        try (Cursor cursor = getReadableDatabase()
                .rawQuery("SELECT state, COUNT(*) FROM uploads GROUP BY state", null)) {
            while (cursor.moveToNext()) {
                counts[cursor.getInt(0)] = cursor.getInt(1);
            }
        }
        return new Counts(counts[0], counts[1], counts[2]);
    }
}
