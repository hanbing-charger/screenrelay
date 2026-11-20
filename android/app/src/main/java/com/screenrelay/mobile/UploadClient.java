package com.screenrelay.mobile;

import android.content.ContentResolver;
import android.content.Context;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.Proxy;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.Base64;
import java.util.function.BooleanSupplier;

final class UploadClient {
    private static final long DIAGNOSTIC_LIMIT = 1024 * 1024;

    private UploadClient() {}

    private record Payload(String name, String kind, String id, String mime, long size) {}

    static boolean checkConnection(Settings.Configuration configuration) throws IOException {
        HttpURLConnection connection = connect(configuration.origin(), "/api/v1/health");
        try {
            return connection.getResponseCode() == HttpURLConnection.HTTP_OK;
        } finally {
            connection.disconnect();
        }
    }

    static int upload(ContentResolver resolver, Settings.Configuration configuration,
                      SyncStore.Upload upload, BooleanSupplier cancelled) throws IOException {
        try (InputStream source = resolver.openInputStream(upload.uri())) {
            if (source == null) {
                throw new IOException("MediaStore returned no stream");
            }
            return upload(configuration, source, new Payload(
                    upload.name(), upload.kind(), upload.id(), upload.mime(), upload.size()), cancelled);
        }
    }

    static void uploadDiagnostic(Context context, Settings.Configuration configuration,
                                 File report, long timestamp) throws IOException {
        if (configuration.origin().isEmpty() || configuration.token().isEmpty()) {
            throw new IOException("请先在首页配对电脑接收端。");
        }
        try (FileInputStream source = new FileInputStream(report)) {
            long size = source.getChannel().size();
            if (size <= 0 || size > DIAGNOSTIC_LIMIT) {
                throw new IOException("诊断文件为空或超过 1 MiB。");
            }
            String identity = new Settings(context).installationId() + "\n" + timestamp + "\n" + report.getName();
            String uploadId = diagnosticUploadId(source, identity);
            source.getChannel().position(0);
            int response;
            try {
                response = upload(configuration, source, new Payload(
                        report.getName(), "diagnostic", uploadId, "text/plain; charset=utf-8", size), () -> false);
            } catch (IOException networkError) {
                throw new IOException("连接中断，请确认电脑接收端正在运行并重试。", networkError);
            }
            switch (response) {
                case HttpURLConnection.HTTP_OK, HttpURLConnection.HTTP_CREATED -> { return; }
                case HttpURLConnection.HTTP_UNAUTHORIZED, HttpURLConnection.HTTP_FORBIDDEN ->
                        throw new IOException("电脑配对已失效，请重新配对。");
                case HttpURLConnection.HTTP_BAD_REQUEST, HttpURLConnection.HTTP_NOT_FOUND,
                     HttpURLConnection.HTTP_BAD_METHOD, HttpURLConnection.HTTP_UNSUPPORTED_TYPE ->
                        throw new IOException("电脑未接收诊断文件，请确认接收端已升级到 v0.6.0 或更新版本。");
                case HttpURLConnection.HTTP_ENTITY_TOO_LARGE ->
                        throw new IOException("诊断文件超过电脑接收端的大小限制。");
                case HttpURLConnection.HTTP_UNAVAILABLE ->
                        throw new IOException("电脑接收端正忙，请稍后重试。");
                default -> throw new IOException("电脑接收失败（HTTP " + response + "）。");
            }
        }
    }

    private static String diagnosticUploadId(InputStream source, String identity) throws IOException {
        MessageDigest digest;
        try {
            digest = MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException unavailable) {
            throw new AssertionError(unavailable);
        }
        digest.update(identity.getBytes(StandardCharsets.UTF_8));
        digest.update((byte) 0);
        byte[] buffer = new byte[16 * 1024];
        int count;
        while ((count = source.read(buffer)) != -1) {
            digest.update(buffer, 0, count);
        }
        return "diagnostic-" + Base64.getUrlEncoder().withoutPadding().encodeToString(digest.digest());
    }

    private static int upload(Settings.Configuration configuration, InputStream source,
                              Payload payload, BooleanSupplier cancelled) throws IOException {
        HttpURLConnection connection = connect(configuration.origin(), "/api/v1/uploads");
        try {
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setFixedLengthStreamingMode(payload.size());
            connection.setRequestProperty("Authorization", "Bearer " + configuration.token());
            connection.setRequestProperty("X-Filename",
                    URLEncoder.encode(payload.name(), "UTF-8").replace("+", "%20").replace("*", "%2A"));
            connection.setRequestProperty("X-Media-Kind", payload.kind());
            connection.setRequestProperty("X-Upload-Id", payload.id());
            connection.setRequestProperty("Content-Type", payload.mime());
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

    static HttpURLConnection connect(String origin, String path) throws IOException {
        HttpURLConnection connection = (HttpURLConnection) new URL(origin + path)
                .openConnection(Proxy.NO_PROXY);
        connection.setConnectTimeout(8_000);
        connection.setReadTimeout(30_000);
        connection.setInstanceFollowRedirects(false);
        return connection;
    }
}
