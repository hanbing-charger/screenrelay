package com.screenrelay.mobile;

import android.app.Application;
import android.app.NotificationManager;
import android.app.job.JobScheduler;

public final class ScreenRelayApplication extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        DiagnosticReports.installJavaCrashHandler(this);
        retireLegacyAutomaticUploads();
    }

    private void retireLegacyAutomaticUploads() {
        JobScheduler jobs = getSystemService(JobScheduler.class);
        if (jobs != null) {
            jobs.cancel(8765);
            jobs.cancel(8766);
        }
        NotificationManager notifications = getSystemService(NotificationManager.class);
        if (notifications != null) {
            notifications.cancel(8765);
        }
        new Settings(this).clearLegacyAutomaticSettings();
    }
}
