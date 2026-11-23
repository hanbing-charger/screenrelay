package com.screenrelay.mobile;

import java.net.URLConnection;
import java.util.Locale;
import java.util.regex.Pattern;

record ManualDocument(String filename, String mime) {
    private static final Pattern UNSAFE_FILENAME = Pattern.compile("[\\p{Cc}\\p{Cf}<>:\"/\\\\|?*]");
    private static final Pattern MIME_TYPE = Pattern.compile("[a-z0-9!#$%&'+.^_`~-]+/[a-z0-9!#$%&'+.^_`~-]+");

    private enum VideoFormat {
        MP4("video/mp4", "mp4", "m4v"),
        QUICKTIME("video/quicktime", "mov"),
        WEBM("video/webm", "webm"),
        MATROSKA("video/x-matroska", "mkv"),
        THREE_GPP("video/3gpp", "3gp", "3gpp"),
        THREE_GPP2("video/3gpp2", "3g2", "3gp2"),
        AVI("video/x-msvideo", "avi"),
        MPEG("video/mpeg", "mpeg", "mpg", "mpe", "m2v"),
        MPEG_TS("video/mp2t", "ts", "mts", "m2ts"),
        WMV("video/x-ms-wmv", "wmv"),
        FLV("video/x-flv", "flv"),
        OGG("video/ogg", "ogv");

        final String mime;
        final String[] extensions;

        VideoFormat(String mime, String... extensions) {
            this.mime = mime;
            this.extensions = extensions;
        }
    }

    static ManualDocument file(String displayName, String reportedMime) {
        String filename = safeName(displayName, "文件");
        String mime = mimeType(reportedMime);
        if (mime.isEmpty()) {
            mime = mimeType(URLConnection.guessContentTypeFromName(filename));
        }
        return new ManualDocument(filename, mime.isEmpty() ? "application/octet-stream" : mime);
    }

    static ManualDocument video(String displayName, String reportedMime) {
        String filename = safeName(displayName, "视频");
        int dot = filename.lastIndexOf('.');
        String extension = dot < 0 ? "" : filename.substring(dot + 1).toLowerCase(Locale.ROOT);
        if ("3gpp2".equals(extension)) {
            return new ManualDocument(safeName(filename.substring(0, dot), "视频") + ".3g2",
                    VideoFormat.THREE_GPP2.mime);
        }
        for (VideoFormat format : VideoFormat.values()) {
            for (String known : format.extensions) {
                if (known.equals(extension)) {
                    return new ManualDocument(filename, format.mime);
                }
            }
        }

        String reported = mimeType(reportedMime);
        String mime = switch (reported) {
            case "video/m4v", "video/x-m4v", "application/mp4" -> "video/mp4";
            case "video/mov", "video/x-quicktime" -> "video/quicktime";
            case "video/matroska", "application/x-matroska" -> "video/x-matroska";
            case "video/3gp" -> "video/3gpp";
            case "video/3g2", "video/3gp2" -> "video/3gpp2";
            case "video/avi", "video/msvideo", "video/vnd.avi" -> "video/x-msvideo";
            case "video/mpg", "video/x-mpeg" -> "video/mpeg";
            case "video/mpegts", "video/x-mpegts" -> "video/mp2t";
            case "video/wmv" -> "video/x-ms-wmv";
            case "video/flv" -> "video/x-flv";
            default -> reported;
        };
        for (VideoFormat format : VideoFormat.values()) {
            if (format.mime.equals(mime)) {
                String stem = dot > 0 ? safeName(filename.substring(0, dot), "视频") : filename;
                return new ManualDocument(stem + "." + format.extensions[0], format.mime);
            }
        }
        throw new IllegalArgumentException("不支持这种视频格式。可用「选择文件上传」发送原文件。");
    }

    private static String safeName(String name, String fallback) {
        if (name == null) {
            return fallback;
        }
        String filename = UNSAFE_FILENAME.matcher(name).replaceAll("_").trim().replaceFirst("[ .]+$", "");
        return filename.isEmpty() ? fallback : filename;
    }

    private static String mimeType(String value) {
        if (value == null) {
            return "";
        }
        int separator = value.indexOf(';');
        String mime = (separator < 0 ? value : value.substring(0, separator)).trim().toLowerCase(Locale.ROOT);
        return MIME_TYPE.matcher(mime).matches() ? mime : "";
    }
}
