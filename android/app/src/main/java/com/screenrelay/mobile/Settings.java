package com.screenrelay.mobile;

import android.Manifest;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.os.Build;

import java.net.URI;
import java.util.UUID;

final class Settings {
    private final SharedPreferences values;

    Settings(Context context) {
        values = context.getSharedPreferences("screenrelay", Context.MODE_PRIVATE);
    }

    record Configuration(String origin, String token) {
        static Configuration fromInput(CharSequence originInput, CharSequence tokenInput) {
            URI uri;
            try {
                uri = new URI(originInput.toString().trim());
            } catch (Exception invalid) {
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
            String token = tokenInput.toString().trim();
            if (token.isEmpty() || token.length() > 512 || !token.matches("[!-~]+")) {
                throw new IllegalArgumentException("请填写电脑接收端显示的配对密钥。");
            }
            return new Configuration(uri.getScheme().toLowerCase(java.util.Locale.ROOT)
                    + "://" + uri.getRawAuthority(), token);
        }
    }

    Configuration configuration() {
        return new Configuration(values.getString("origin", ""), values.getString("token", ""));
    }

    boolean isEnabled() {
        return values.getBoolean("enabled", false);
    }

    int revision() {
        return values.getInt("revision", 0);
    }

    long firstEnabledAt() {
        return values.getLong("firstEnabledAt", -1);
    }

    synchronized String installationId() {
        String id = values.getString("installationId", "");
        if (id.isEmpty()) {
            id = UUID.randomUUID().toString();
            values.edit().putString("installationId", id).commit();
        }
        return id;
    }

    void enable(Configuration configuration) {
        long firstEnabledAt = firstEnabledAt();
        values.edit().putString("origin", configuration.origin())
                .putString("token", configuration.token())
                .putBoolean("enabled", true)
                .putInt("revision", revision() + 1)
                .putLong("firstEnabledAt", firstEnabledAt < 0
                        ? System.currentTimeMillis() / 1000 : firstEnabledAt)
                .apply();
    }

    void disable() {
        values.edit().putBoolean("enabled", false).putInt("revision", revision() + 1).apply();
    }

    void setStatus(String status) {
        values.edit().putString("status", status).apply();
    }

    String status() {
        return values.getString("status", "");
    }

    static String[] mediaPermissions() {
        if (Build.VERSION.SDK_INT >= 34) {
            return new String[]{Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO,
                    Manifest.permission.READ_MEDIA_VISUAL_USER_SELECTED};
        }
        if (Build.VERSION.SDK_INT >= 33) {
            return new String[]{Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO};
        }
        return new String[]{Manifest.permission.READ_EXTERNAL_STORAGE};
    }

    static boolean hasMediaAccess(Context context) {
        if (Build.VERSION.SDK_INT >= 33) {
            return granted(context, Manifest.permission.READ_MEDIA_IMAGES)
                    && granted(context, Manifest.permission.READ_MEDIA_VIDEO);
        }
        return granted(context, Manifest.permission.READ_EXTERNAL_STORAGE);
    }

    static boolean granted(Context context, String permission) {
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    }
}
