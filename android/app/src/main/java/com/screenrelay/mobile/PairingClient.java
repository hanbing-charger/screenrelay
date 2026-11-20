package com.screenrelay.mobile;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;

final class PairingClient {
    private static final String INVALID_QR = "请扫描电脑接收端显示的截屏快传配对二维码。";

    private PairingClient() {}

    record Request(String origin, String code) {}

    static Request readQr(String contents) {
        if (contents == null || contents.length() > 2048) {
            throw new IllegalArgumentException(INVALID_QR);
        }
        try {
            URI uri = new URI(contents.trim());
            if (!"screenrelay".equalsIgnoreCase(uri.getScheme())
                    || !"pair".equalsIgnoreCase(uri.getRawAuthority())
                    || !"".equals(uri.getRawPath()) || uri.getRawFragment() != null
                    || uri.getRawQuery() == null) {
                throw new IllegalArgumentException(INVALID_QR);
            }
            Map<String, String> fields = new HashMap<>();
            for (String field : uri.getRawQuery().split("&", -1)) {
                int separator = field.indexOf('=');
                if (separator < 1) {
                    throw new IllegalArgumentException(INVALID_QR);
                }
                String key = field.substring(0, separator);
                String value = URLDecoder.decode(field.substring(separator + 1).replace("+", "%2B"), "UTF-8");
                if (fields.putIfAbsent(key, value) != null) {
                    throw new IllegalArgumentException(INVALID_QR);
                }
            }
            String code = fields.get("code");
            String address = fields.get("url");
            if (fields.size() != 3 || !"1".equals(fields.get("v")) || address == null
                    || code == null || !code.matches("[A-Za-z0-9_-]{43}")) {
                throw new IllegalArgumentException(INVALID_QR);
            }
            return new Request(Settings.Configuration.normalizedOrigin(address), code);
        } catch (URISyntaxException | IOException | IllegalArgumentException invalid) {
            throw new IllegalArgumentException(INVALID_QR);
        }
    }

    static Settings.Configuration pair(Request request, String installationId, String deviceName)
            throws IOException {
        HttpURLConnection connection = UploadClient.connect(request.origin(), "/api/v1/pair");
        try {
            JSONObject payload = new JSONObject();
            payload.put("pairingCode", request.code());
            payload.put("deviceId", installationId);
            payload.put("deviceName", deviceName);
            byte[] body = payload.toString().getBytes(StandardCharsets.UTF_8);

            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setUseCaches(false);
            connection.setFixedLengthStreamingMode(body.length);
            connection.setRequestProperty("Content-Type", "application/json");
            try (OutputStream output = connection.getOutputStream()) {
                output.write(body);
            }

            int responseCode = connection.getResponseCode();
            if (responseCode == HttpURLConnection.HTTP_UNAUTHORIZED) {
                throw new PairingFailure("配对码无效或已过期，请在电脑上刷新二维码后重试。");
            }
            if (responseCode == HttpURLConnection.HTTP_NOT_FOUND) {
                throw new PairingFailure("电脑接收端未提供扫码配对。请更新接收端或手动配对。");
            }
            if (responseCode != HttpURLConnection.HTTP_OK && responseCode != HttpURLConnection.HTTP_CREATED) {
                throw new PairingFailure("电脑未能完成配对（HTTP " + responseCode + "）。");
            }
            try (InputStream input = connection.getInputStream()) {
                JSONObject response = new JSONObject(readResponse(input));
                if (!(response.opt("token") instanceof String token)) {
                    throw new PairingFailure("电脑未返回有效的配对密钥，请在电脑上刷新二维码后重试。");
                }
                return Settings.Configuration.fromInput(request.origin(), token);
            }
        } catch (JSONException | IllegalArgumentException invalid) {
            throw new PairingFailure("电脑未返回有效的配对密钥，请在电脑上刷新二维码后重试。");
        } finally {
            connection.disconnect();
        }
    }

    private static String readResponse(InputStream input) throws IOException {
        byte[] buffer = new byte[4096];
        int size = 0;
        while (size < buffer.length) {
            int count = input.read(buffer, size, buffer.length - size);
            if (count == -1) {
                return new String(buffer, 0, size, StandardCharsets.UTF_8);
            }
            size += count;
        }
        if (input.read() != -1) {
            throw new PairingFailure("电脑配对响应过长，请重试。");
        }
        return new String(buffer, 0, size, StandardCharsets.UTF_8);
    }

    static final class PairingFailure extends IOException {
        PairingFailure(String message) {
            super(message);
        }
    }
}
