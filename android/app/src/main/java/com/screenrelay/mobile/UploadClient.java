package com.screenrelay.mobile;

import android.content.ContentResolver;

import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.net.URLEncoder;
import java.util.function.BooleanSupplier;

final class UploadClient {
    private UploadClient() {}

    static boolean checkConnection(Settings.Configuration configuration) throws IOException {
        HttpURLConnection connection = connect(configuration, "/api/v1/health");
        try {
            return connection.getResponseCode() == HttpURLConnection.HTTP_OK;
        } finally {
            connection.disconnect();
        }
    }

    static int upload(ContentResolver resolver, Settings.Configuration configuration,
                      SyncStore.Upload upload, BooleanSupplier cancelled) throws IOException {
        HttpURLConnection connection = connect(configuration, "/api/v1/uploads");
        try (InputStream source = resolver.openInputStream(upload.uri())) {
            if (source == null) {
                throw new IOException("MediaStore returned no stream");
            }
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setFixedLengthStreamingMode(upload.size());
            connection.setRequestProperty("Authorization", "Bearer " + configuration.token());
            connection.setRequestProperty("X-Filename",
                    URLEncoder.encode(upload.name(), "UTF-8").replace("+", "%20").replace("*", "%2A"));
            connection.setRequestProperty("X-Media-Kind", upload.kind());
            connection.setRequestProperty("X-Upload-Id", upload.id());
            connection.setRequestProperty("Content-Type", upload.mime());
            connection.setRequestProperty("Expect", "100-continue");
            try (OutputStream target = connection.getOutputStream()) {
                byte[] buffer = new byte[64 * 1024];
                int count;
                while (!cancelled.getAsBoolean() && (count = source.read(buffer)) != -1) {
                    target.write(buffer, 0, count);
                }
                if (cancelled.getAsBoolean()) {
                    throw new InterruptedIOException("Upload was cancelled");
                }
            } catch (IOException transferFailed) {
                if (!cancelled.getAsBoolean()) {
                    try {
                        int response = connection.getResponseCode();
                        if (response >= 401) {
                            return response;
                        }
                    } catch (IOException responseUnavailable) {
                        // The receiver may already have closed the connection.
                    }
                }
                throw transferFailed;
            }
            return connection.getResponseCode();
        } finally {
            connection.disconnect();
        }
    }

    private static HttpURLConnection connect(Settings.Configuration configuration, String path)
            throws IOException {
        HttpURLConnection connection = (HttpURLConnection) new URL(configuration.origin() + path)
                .openConnection();
        connection.setConnectTimeout(8_000);
        connection.setReadTimeout(30_000);
        connection.setInstanceFollowRedirects(false);
        return connection;
    }
}
