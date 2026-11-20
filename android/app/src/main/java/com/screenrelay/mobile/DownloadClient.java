package com.screenrelay.mobile;

import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.io.InterruptedIOException;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.StandardCharsets;
import java.util.Locale;
import java.util.function.BooleanSupplier;
import java.util.function.LongConsumer;
import java.util.regex.Pattern;

final class DownloadClient {
    private static final Pattern ENCODED_NAME = Pattern.compile("[\\x21-\\x7E]{1,4096}");
    private static final Pattern STRONG_ETAG = Pattern.compile("\"[\\x21\\x23-\\x7E\\x80-\\xFF]*\"");
    private static final Pattern MIME = Pattern.compile("[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+");
    private static final Pattern DECIMAL = Pattern.compile("[0-9]+");

    private DownloadClient() {}

    record Request(String origin, String code) {}

    record Metadata(String filename, String mime, long length, String etag) {}

    static Metadata inspect(Request request) throws IOException {
        HttpURLConnection connection = connect(request);
        try {
            connection.setRequestMethod("HEAD");
            requireStatus(connection.getResponseCode(), HttpURLConnection.HTTP_OK);
            requireIdentityEncoding(connection);
            return new Metadata(decodeFilename(connection.getHeaderField("X-Filename")),
                    mimeType(connection.getHeaderField("Content-Type")),
                    parseLength(connection.getHeaderField("Content-Length")), entityTag(connection));
        } finally {
            connection.disconnect();
        }
    }

    static void transfer(Request request, Metadata metadata, long offset, OutputStream target,
                         LongConsumer progress, BooleanSupplier cancelled) throws IOException {
        if (offset < 0 || offset > metadata.length()) {
            throw new Rejected("下载进度无效，请重新下载文件。");
        }
        checkCancelled(cancelled);
        if (offset == metadata.length()) {
            progress.accept(offset);
            return;
        }

        HttpURLConnection connection = connect(request);
        try {
            connection.setRequestMethod("GET");
            if (offset != 0) {
                connection.setRequestProperty("Range", "bytes=" + offset + "-");
                connection.setRequestProperty("If-Range", metadata.etag());
            }
            int status = connection.getResponseCode();
            checkCancelled(cancelled);
            requireStatus(status, offset == 0 ? HttpURLConnection.HTTP_OK : HttpURLConnection.HTTP_PARTIAL);
            requireIdentityEncoding(connection);
            if (!metadata.etag().equals(entityTag(connection))) {
                throw new Rejected("电脑上的文件已变化，请重新扫码下载。");
            }
            if (offset != 0) {
                String expected = "bytes " + offset + "-" + (metadata.length() - 1) + "/" + metadata.length();
                if (!expected.equals(connection.getHeaderField("Content-Range"))) {
                    throw new Rejected("电脑返回的续传范围无效，请重新下载文件。");
                }
            }
            String contentLength = connection.getHeaderField("Content-Length");
            if (contentLength != null && parseLength(contentLength) != metadata.length() - offset) {
                throw new Rejected("电脑返回的文件大小与下载信息不一致。");
            }

            try (InputStream source = connection.getInputStream()) {
                byte[] buffer = new byte[64 * 1024];
                long position = offset;
                while (position < metadata.length()) {
                    checkCancelled(cancelled);
                    int count = source.read(buffer, 0, (int) Math.min(buffer.length, metadata.length() - position));
                    checkCancelled(cancelled);
                    if (count <= 0) {
                        throw new EOFException("文件下载中断，可以继续下载。");
                    }
                    target.write(buffer, 0, count);
                    position += count;
                    progress.accept(position);
                }
                checkCancelled(cancelled);
                if (source.read() != -1) {
                    throw new Rejected("电脑返回的数据超过文件大小。");
                }
                checkCancelled(cancelled);
            }
        } catch (IOException failure) {
            checkCancelled(cancelled);
            throw failure;
        } finally {
            connection.disconnect();
        }
    }

    private static HttpURLConnection connect(Request request) throws IOException {
        HttpURLConnection connection = UploadClient.connect(request.origin(), "/api/v1/download");
        connection.setUseCaches(false);
        connection.setRequestProperty("Accept-Encoding", "identity");
        connection.setRequestProperty("Authorization", "Bearer " + request.code());
        return connection;
    }

    private static void requireStatus(int status, int expected) throws IOException {
        if (status == expected) {
            return;
        }
        if (status == HttpURLConnection.HTTP_GONE) {
            throw new Rejected("下载码已过期或电脑上的文件已变化，请重新生成二维码。");
        }
        if (status == -1 || status == HttpURLConnection.HTTP_CLIENT_TIMEOUT || status == 429
                || (status >= 500 && status < 600)) {
            throw new IOException("电脑暂时无法发送文件（HTTP " + status + "）。");
        }
        if (expected == HttpURLConnection.HTTP_PARTIAL && status == HttpURLConnection.HTTP_OK) {
            throw new Rejected("电脑无法续传此文件，请重新扫码下载。");
        }
        throw new Rejected("电脑无法发送此文件（HTTP " + status + "）。");
    }

    private static void requireIdentityEncoding(HttpURLConnection connection) throws Rejected {
        String coding = connection.getHeaderField("Content-Encoding");
        if (coding != null && !"identity".equalsIgnoreCase(coding)) {
            throw new Rejected("电脑返回了不支持的文件编码。");
        }
    }

    private static String entityTag(HttpURLConnection connection) throws Rejected {
        String etag = connection.getHeaderField("ETag");
        if (etag == null || !STRONG_ETAG.matcher(etag).matches()) {
            throw new Rejected("电脑返回的文件标识无效。");
        }
        return etag;
    }

    private static long parseLength(String length) throws Rejected {
        if (length != null && DECIMAL.matcher(length).matches()) {
            try {
                return Long.parseLong(length);
            } catch (NumberFormatException overflow) {
                // A file size outside the signed long range cannot be downloaded.
            }
        }
        throw new Rejected("电脑返回的文件大小无效。");
    }

    private static String mimeType(String header) throws Rejected {
        if (header == null) {
            return "application/octet-stream";
        }
        int parameters = header.indexOf(';');
        String value = (parameters < 0 ? header : header.substring(0, parameters)).trim().toLowerCase(Locale.ROOT);
        if (!MIME.matcher(value).matches()) {
            throw new Rejected("电脑返回的文件类型无效。");
        }
        return value;
    }

    private static String decodeFilename(String encoded) throws Rejected {
        String error = "电脑返回的文件名无效。";
        if (encoded == null || !ENCODED_NAME.matcher(encoded).matches()) {
            throw new Rejected(error);
        }
        ByteBuffer bytes = ByteBuffer.allocate(encoded.length());
        for (int i = 0; i < encoded.length(); i++) {
            int value = encoded.charAt(i);
            if (value == '%') {
                if (i + 2 >= encoded.length()) {
                    throw new Rejected(error);
                }
                int high = Character.digit(encoded.charAt(++i), 16);
                int low = Character.digit(encoded.charAt(++i), 16);
                if (high < 0 || low < 0) {
                    throw new Rejected(error);
                }
                value = (high << 4) | low;
            }
            bytes.put((byte) value);
        }
        bytes.flip();
        try {
            String name = StandardCharsets.UTF_8.newDecoder().decode(bytes).toString();
            if (name.trim().isEmpty() || ".".equals(name) || "..".equals(name) || name.indexOf('/') >= 0
                    || name.indexOf('\\') >= 0 || name.chars().anyMatch(Character::isISOControl)) {
                throw new Rejected(error);
            }
            return name;
        } catch (CharacterCodingException invalid) {
            throw new Rejected(error);
        }
    }

    private static void checkCancelled(BooleanSupplier cancelled) throws InterruptedIOException {
        if (cancelled.getAsBoolean()) {
            throw new InterruptedIOException("已取消下载。");
        }
    }

    static final class Rejected extends IOException {
        Rejected(String message) {
            super(message);
        }
    }
}
