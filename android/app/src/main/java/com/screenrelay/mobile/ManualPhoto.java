package com.screenrelay.mobile;

import java.nio.charset.StandardCharsets;
import java.util.Locale;

record ManualPhoto(String filename, String mime) {
    private enum Format {
        JPEG("image/jpeg", "jpg", "jpeg", "jpe", "jfif"),
        PNG("image/png", "png"),
        WEBP("image/webp", "webp"),
        HEIC("image/heic", "heic"),
        HEIF("image/heif", "heif", "hif"),
        HEIC_SEQUENCE("image/heic-sequence", "heics"),
        HEIF_SEQUENCE("image/heif-sequence", "heifs"),
        AVIF("image/avif", "avif"),
        GIF("image/gif", "gif"),
        BMP("image/bmp", "bmp"),
        JXL("image/jxl", "jxl"),
        TIFF("image/tiff", "tif", "tiff"),
        DNG("image/x-adobe-dng", "dng");

        final String mime;
        final String[] extensions;

        Format(String mime, String... extensions) {
            this.mime = mime;
            this.extensions = extensions;
        }
    }

    static ManualPhoto identify(String displayName, String reportedMime, byte[] prefix) {
        String name = displayName == null ? "" : displayName.replaceAll("[\\p{Cc}\\p{Cf}<>:\"/\\\\|?*]", "_").trim();
        int dot = name.lastIndexOf('.');
        String extension = dot < 0 ? "" : name.substring(dot + 1);
        Format fromName = byExtension(extension.toLowerCase(Locale.ROOT));
        Format fromMime = byMime(reportedMime);
        Format signature = detect(prefix, fromName == Format.DNG || fromMime == Format.DNG,
                fromMime == null ? fromName : fromMime);
        Format format = signature != null ? signature : (fromMime == null ? fromName : fromMime);
        if (format == null) {
            throw new IllegalArgumentException("不支持这种图片格式，请选择 JPEG、PNG、HEIC 或其他常见图片。");
        }

        String stem = (extension.isEmpty() ? name : name.substring(0, dot)).replaceAll("^[ .]+|[ .]+$", "");
        if (stem.isEmpty()) {
            stem = "图片";
        }
        String suffix = format == fromName ? extension : format.extensions[0];
        int points = stem.codePointCount(0, stem.length());
        if (points > 80) {
            stem = stem.substring(0, stem.offsetByCodePoints(0, 80));
        }
        return new ManualPhoto(stem + "." + suffix, format.mime);
    }

    private static Format byExtension(String extension) {
        for (Format format : Format.values()) {
            for (String known : format.extensions) {
                if (known.equals(extension)) {
                    return format;
                }
            }
        }
        return null;
    }

    private static Format byMime(String mime) {
        if (mime == null) {
            return null;
        }
        String normalized = mime.split(";", 2)[0].trim().toLowerCase(Locale.ROOT);
        normalized = switch (normalized) {
            case "image/jpg", "image/pjpeg" -> "image/jpeg";
            case "image/x-png" -> "image/png";
            case "image/x-ms-bmp" -> "image/bmp";
            case "image/jpeg-xl" -> "image/jxl";
            case "image/dng", "image/vnd.adobe.dng" -> "image/x-adobe-dng";
            default -> normalized;
        };
        for (Format format : Format.values()) {
            if (format.mime.equals(normalized)) {
                return format;
            }
        }
        return null;
    }

    private static Format detect(byte[] data, boolean dng, Format reported) {
        if (data.length < 12) {
            return null;
        }
        int first = data[0] & 0xff;
        int second = data[1] & 0xff;
        if (first == 0xff && second == 0xd8 && (data[2] & 0xff) == 0xff) {
            return Format.JPEG;
        }
        if (first == 0x89 && ascii(data, 1, 3).equals("PNG")) {
            return Format.PNG;
        }
        if (ascii(data, 0, 4).equals("RIFF") && ascii(data, 8, 4).equals("WEBP")) {
            return Format.WEBP;
        }
        if (ascii(data, 0, 4).equals("GIF8")) {
            return Format.GIF;
        }
        if (first == 'B' && second == 'M') {
            return Format.BMP;
        }
        if ((first == 'I' && second == 'I' && data[2] == 42 && data[3] == 0)
                || (first == 'M' && second == 'M' && data[2] == 0 && data[3] == 42)) {
            return dng ? Format.DNG : Format.TIFF;
        }
        if ((first == 0xff && second == 0x0a) || ascii(data, 4, 4).equals("JXL ")) {
            return Format.JXL;
        }
        if (!ascii(data, 4, 4).equals("ftyp")) {
            return null;
        }
        return switch (ascii(data, 8, 4)) {
            case "avif", "avis" -> Format.AVIF;
            case "heic", "heix", "heim", "heis" -> Format.HEIC;
            case "hevc", "hevx", "hevm", "hevs" -> Format.HEIC_SEQUENCE;
            case "msf1" -> reported == Format.HEIC_SEQUENCE ? reported : Format.HEIF_SEQUENCE;
            case "mif1" -> reported == Format.HEIC || reported == Format.AVIF ? reported : Format.HEIF;
            default -> null;
        };
    }

    private static String ascii(byte[] bytes, int offset, int length) {
        return new String(bytes, offset, length, StandardCharsets.US_ASCII);
    }
}
