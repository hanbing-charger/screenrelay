package com.screenrelay.mobile;

import android.app.job.JobInfo;
import android.app.job.JobParameters;
import android.app.job.JobScheduler;
import android.app.job.JobService;
import android.content.ComponentName;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

public final class SyncJob extends JobService {
    private static final int PERIODIC = 8765;
    private static final int MEDIA_CHANGED = 8766;
    private final Map<Integer, AtomicBoolean> runs = new HashMap<>();
    private final Handler main = new Handler(Looper.getMainLooper());

    static boolean ensureScheduled(Context context) {
        JobScheduler scheduler = context.getSystemService(JobScheduler.class);
        boolean periodic = scheduler.getPendingJob(PERIODIC) != null ||
                scheduler.schedule(new JobInfo.Builder(PERIODIC, new ComponentName(context, SyncJob.class))
                        .setPeriodic(15 * 60_000L)
                        .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                        .setPersisted(true)
                        .build()) == JobScheduler.RESULT_SUCCESS;
        if (scheduler.getPendingJob(MEDIA_CHANGED) == null) {
            scheduleMediaChanges(context);
        }
        return periodic;
    }

    static void cancel(Context context) {
        JobScheduler scheduler = context.getSystemService(JobScheduler.class);
        scheduler.cancel(PERIODIC);
        scheduler.cancel(MEDIA_CHANGED);
    }

    private static void scheduleMediaChanges(Context context) {
        context.getSystemService(JobScheduler.class).schedule(
                new JobInfo.Builder(MEDIA_CHANGED, new ComponentName(context, SyncJob.class))
                        .addTriggerContentUri(new JobInfo.TriggerContentUri(
                                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                                JobInfo.TriggerContentUri.FLAG_NOTIFY_FOR_DESCENDANTS))
                        .addTriggerContentUri(new JobInfo.TriggerContentUri(
                                MediaStore.Video.Media.EXTERNAL_CONTENT_URI,
                                JobInfo.TriggerContentUri.FLAG_NOTIFY_FOR_DESCENDANTS))
                        .setTriggerContentUpdateDelay(2_000L)
                        .setTriggerContentMaxDelay(10_000L)
                        .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                        .build());
    }

    @Override
    public boolean onStartJob(JobParameters parameters) {
        int id = parameters.getJobId();
        AtomicBoolean cancelled = new AtomicBoolean();
        runs.put(id, cancelled);
        SyncEngine.submit(this, cancelled::get, ignored -> main.post(() -> {
            if (runs.get(id) != cancelled) {
                return;
            }
            runs.remove(id);
            jobFinished(parameters, false);
            if (!new Settings(this).isEnabled()) {
                return;
            }
            if (id == MEDIA_CHANGED) {
                scheduleMediaChanges(this);
            } else {
                ensureScheduled(this);
            }
        }));
        return true;
    }

    @Override
    public boolean onStopJob(JobParameters parameters) {
        AtomicBoolean cancelled = runs.remove(parameters.getJobId());
        if (cancelled != null) {
            cancelled.set(true);
        }
        return new Settings(this).isEnabled();
    }
}
