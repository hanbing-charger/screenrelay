package com.screenrelay.mobile;

import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;

import java.net.URI;
import java.net.URISyntaxException;
import java.util.Locale;
import java.util.UUID;

final class Settings {
    private static final Object INSTALLATION_ID_LOCK = new Object();
    private final SharedPreferences values;

    Settings(Context context) {
        values = context.getSharedPreferences("screenrelay", Context.MODE_PRIVATE);
    }

    record Configuration(String origin, String token) {
        static Configuration fromInput(CharSequence originInput, CharSequence tokenInput) {
            String origin = normalizedOrigin(originInput);
            String token = tokenInput.toString().trim();
            if (token.isEmpty() || token.length() > 512 || !token.matches("[!-~]+")) {
                throw new IllegalArgumentException("请填写电脑接收端显示的配对密钥。");
            }
            return new Configuration(origin, token);
        }

        static String normalizedOrigin(CharSequence originInput) {
            URI uri;
            try {
                uri = new URI(originInput.toString().trim());
            } catch (URISyntaxException invalid) {
                throw new IllegalArgumentException("请填写有效的电脑地址。");
            }
            String scheme = uri.getScheme();
            if ((!"http".equalsIgnoreCase(scheme) && !"https".equalsIgnoreCase(scheme))
                    || uri.getHost() == null || uri.getRawUserInfo() != null
                    || uri.getRawQuery() != null || uri.getRawFragment() != null
                    || uri.getPort() == 0 || uri.getPort() > 65535
                    || (!uri.getPath().isEmpty() && !"/".equals(uri.getPath()))) {
                throw new IllegalArgumentException("请使用电脑上显示的 HTTP 或 HTTPS 地址。");
            }
            return uri.getScheme().toLowerCase(Locale.ROOT) + "://" + uri.getRawAuthority();
        }
    }

    Configuration configuration() {
        return new Configuration(values.getString("origin", ""), values.getString("token", ""));
    }

    String installationId() {
        synchronized (INSTALLATION_ID_LOCK) {
            String id = values.getString("installationId", "");
            if (id.isEmpty()) {
                id = UUID.randomUUID().toString();
                values.edit().putString("installationId", id).commit();
            }
            return id;
        }
    }

    void saveConfiguration(Configuration configuration) {
        values.edit().putString("origin", configuration.origin())
                .putString("token", configuration.token())
                .apply();
    }

    void clearLegacyAutomaticSettings() {
        values.edit().remove("enabled").remove("firstEnabledAt").remove("revision").remove("status").apply();
    }

    static boolean granted(Context context, String permission) {
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    }
}
