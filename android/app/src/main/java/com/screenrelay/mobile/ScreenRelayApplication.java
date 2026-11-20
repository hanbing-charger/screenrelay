package com.screenrelay.mobile;

import android.app.Application;

public final class ScreenRelayApplication extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        DiagnosticReports.installJavaCrashHandler(this);
    }
}
