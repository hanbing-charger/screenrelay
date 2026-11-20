package com.screenrelay.mobile;

import java.io.IOException;
import java.net.URI;
import java.net.URISyntaxException;
import java.net.URLDecoder;
import java.util.HashMap;
import java.util.Map;

record ReceiverQr(String origin, String code) {
    static ReceiverQr read(String contents, String kind, String error) {
        if (contents == null || contents.length() > 2048) {
            throw new IllegalArgumentException(error);
        }
        try {
            URI uri = new URI(contents.trim());
            if (!"screenrelay".equalsIgnoreCase(uri.getScheme())
                    || !kind.equalsIgnoreCase(uri.getRawAuthority())
                    || !"".equals(uri.getRawPath()) || uri.getRawFragment() != null
                    || uri.getRawQuery() == null) {
                throw new IllegalArgumentException(error);
            }
            Map<String, String> fields = new HashMap<>();
            for (String field : uri.getRawQuery().split("&", -1)) {
                int separator = field.indexOf('=');
                if (separator < 1) {
                    throw new IllegalArgumentException(error);
                }
                String key = field.substring(0, separator);
                String value = URLDecoder.decode(field.substring(separator + 1).replace("+", "%2B"), "UTF-8");
                if (fields.putIfAbsent(key, value) != null) {
                    throw new IllegalArgumentException(error);
                }
            }
            String code = fields.get("code");
            String address = fields.get("url");
            if (fields.size() != 3 || !"1".equals(fields.get("v")) || address == null
                    || code == null || !code.matches("[A-Za-z0-9_-]{43}")) {
                throw new IllegalArgumentException(error);
            }
            return new ReceiverQr(Settings.Configuration.normalizedOrigin(address), code);
        } catch (URISyntaxException | IOException | IllegalArgumentException invalid) {
            throw new IllegalArgumentException(error);
        }
    }
}
