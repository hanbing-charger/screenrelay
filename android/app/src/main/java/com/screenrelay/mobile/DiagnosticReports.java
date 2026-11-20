package com.screenrelay.mobile;

import android.annotation.TargetApi;
import android.app.ActivityManager;
import android.app.Application;
import android.app.ApplicationExitInfo;
import android.content.Context;
import android.os.Build;
import android.os.Process;
import android.util.AtomicFile;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.PrintWriter;
import java.io.Writer;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.time.Instant;
import java.time.ZoneOffset;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

final class DiagnosticReports {
    private static final long DAY_MS = 24 * 60 * 60 * 1000L;
    private static final long MERGE_WINDOW_MS = 2 * 60 * 1000L;
    private static final int TRACE_BYTES = 256 * 1024;
    private static final int REPORT_CHARS = 240 * 1024;
    private static final int MAX_JAVA_CRASHES = 32;
    private static final Pattern JAVA_FILE = Pattern.compile("java-(\\d+)-(\\d+)\\.txt");
    private static final Pattern PROCESS_HEADER = Pattern.compile("(?m)^----- pid (\\d+) at [^\\r\\n]*-----\\r?$");
    private static final Pattern PROCESS_END = Pattern.compile("(?m)^----- end (\\d+) -----[^\\S\\r\\n]*\\r?$");
    private static final Pattern COMMAND_LINE = Pattern.compile("(?m)^Cmd line:\\s*([^\\r\\n]+)");
    private static final Pattern BEARER = Pattern.compile("(?i)(\\bbearer\\s+)[A-Za-z0-9_./~+=-]+");
    private static final Pattern CREDENTIAL_FIELD = Pattern.compile(
            "(?i)(\\b(?:password|passwd|passphrase|secret|pairingCode|pairing[-_]key|(?:access|auth|refresh)[_-]?token|token)"
                    + "\\b[\"']?[^\\S\\r\\n]*[:=][^\\S\\r\\n]*)[^\\r\\n]+");
    private static final Pattern QR_CODE = Pattern.compile("(?i)([?&]code=)[^&\\s\"'\\]}]+");
    private static final Pattern URL_PASSWORD = Pattern.compile("(://[^\\s/@:]+:)[^\\s/@]+(@)");
    private static final Pattern RELAY_SECRET = Pattern.compile("(?<![A-Za-z0-9_-])[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])");
    private static final DateTimeFormatter REPORT_TIME = DateTimeFormatter
            .ofPattern("uuuuMMdd-HHmmss-SSS").withZone(ZoneOffset.UTC);
    private static final String HIDDEN = "[已省略]";
    private static final String TRACE_LIMIT = "\n[跟踪已达到报告大小上限]\n";

    private DiagnosticReports() {}

    static final class Report {
        final File file;
        final long timestamp;
        final String kind;
        final String processName;

        Report(File file, long timestamp, String kind, String processName) {
            this.file = file;
            this.timestamp = timestamp;
            this.kind = kind;
            this.processName = processName;
        }
    }

    private record JavaCrash(File file, long time, int pid) {}

    private record JavaTrace(String process, String contents) {}

    static void installJavaCrashHandler(Context context) {
        Thread.UncaughtExceptionHandler previous = Thread.getDefaultUncaughtExceptionHandler();
        if (previous == null) {
            return;
        }
        AtomicBoolean recording = new AtomicBoolean();
        Thread.setDefaultUncaughtExceptionHandler((thread, failure) -> {
            try {
                if (recording.compareAndSet(false, true)) {
                    saveJavaCrash(context, thread, failure);
                }
            } catch (Throwable ignored) {
                // The platform's normal crash handling must run even when capture fails.
            } finally {
                previous.uncaughtException(thread, failure);
            }
        });
    }

    private static void saveJavaCrash(Context context, Thread thread, Throwable failure) throws IOException {
        long timestamp = System.currentTimeMillis();
        File directory = javaDirectory(context);
        Files.createDirectories(directory.toPath());
        List<JavaCrash> older = recentJavaCrashes(directory, timestamp);
        for (int i = MAX_JAVA_CRASHES - 1; i < older.size(); i++) {
            older.get(i).file().delete();
        }

        LimitedWriter stack = new LimitedWriter();
        failure.printStackTrace(new PrintWriter(stack));
        String process = ownProcess(context, Application.getProcessName());
        String text = process + "\n线程    " + thread.getName() + "\n" + stack;
        writeAtomic(new File(directory, "java-" + timestamp + "-" + Process.myPid() + ".txt"),
                bounded(redact(text, "", "")));
    }

    static synchronized List<Report> load(Context context) throws IOException {
        long now = System.currentTimeMillis();
        File directory = new File(context.getFilesDir(), "diagnostic-reports");
        Files.createDirectories(directory.toPath());
        pruneReports(directory, now);
        List<JavaCrash> javaCrashes = recentJavaCrashes(javaDirectory(context), now);
        List<Report> reports = new ArrayList<>();
        Set<File> merged = new HashSet<>();
        String pairingToken = new Settings(context).configuration().token();
        String downloadCode = context.getSharedPreferences("incoming-download", Context.MODE_PRIVATE)
                .getString("code", "");

        if (Build.VERSION.SDK_INT >= 30) {
            loadPlatform(context, directory, now, javaCrashes, merged, reports, pairingToken, downloadCode);
        }
        for (JavaCrash crash : javaCrashes) {
            if (merged.contains(crash.file())) {
                continue;
            }
            try {
                JavaTrace trace = javaTrace(context, crash);
                String report = header("Crash", "Java 未捕获异常", crash.time(), trace.process(), crash.pid())
                        + "\n应用 Java 堆栈\n" + trace.contents();
                reports.add(writeReport(directory, "Crash", "java", crash.time(), trace.process(), crash.pid(),
                        report, pairingToken, downloadCode));
            } catch (IOException | RuntimeException unavailable) {
                // An unreadable record should not hide the remaining diagnostics.
            }
        }
        reports.sort(Comparator.comparingLong((Report report) -> report.timestamp).reversed());
        return reports;
    }

    @TargetApi(30)
    private static void loadPlatform(Context context, File directory, long now, List<JavaCrash> javaCrashes,
                                     Set<File> merged, List<Report> reports, String pairingToken,
                                     String downloadCode) {
        List<ApplicationExitInfo> exits;
        try {
            ActivityManager manager = context.getSystemService(ActivityManager.class);
            if (manager == null) {
                return;
            }
            exits = manager.getHistoricalProcessExitReasons(context.getPackageName(), 0, 100);
        } catch (RuntimeException unavailable) {
            return;
        }
        if (exits == null) {
            return;
        }

        for (ApplicationExitInfo exit : exits) {
            if (exit == null || !recent(exit.getTimestamp(), now) || !isOwnProcess(context, exit.getProcessName())) {
                continue;
            }
            int reason = exit.getReason();
            if (reason != ApplicationExitInfo.REASON_ANR && reason != ApplicationExitInfo.REASON_CRASH
                    && reason != ApplicationExitInfo.REASON_CRASH_NATIVE) {
                continue;
            }
            try {
                String process = exit.getProcessName();
                JavaCrash local = reason == ApplicationExitInfo.REASON_CRASH
                        ? matchJavaCrash(context, javaCrashes, merged, exit.getTimestamp(), exit.getPid(), process)
                        : null;
                long time = local == null ? exit.getTimestamp() : local.time();
                String kind = reason == ApplicationExitInfo.REASON_ANR ? "ANR" : "Crash";
                String category = switch (reason) {
                    case ApplicationExitInfo.REASON_ANR -> "应用无响应";
                    case ApplicationExitInfo.REASON_CRASH_NATIVE -> "本机代码崩溃";
                    default -> "Java 崩溃";
                };
                String origin = local == null ? "exit-" + reason : "java";
                StringBuilder text = new StringBuilder(header(kind, category, time, process, exit.getPid()));
                text.append("系统退出状态    ").append(exit.getStatus()).append('\n');
                String description = exit.getDescription();
                if (description != null && !description.trim().isEmpty()) {
                    text.append("系统摘要    ").append(description, 0, Math.min(description.length(), 4096)).append('\n');
                }
                if (local != null) {
                    text.append("\n应用 Java 堆栈\n").append(javaTrace(context, local).contents()).append('\n');
                }
                if (reason != ApplicationExitInfo.REASON_CRASH) {
                    text.append("\n系统跟踪\n").append(platformTrace(exit));
                } else if (local == null) {
                    text.append("\n这次退出的 Java 堆栈未由系统保留。\n");
                }
                reports.add(writeReport(directory, kind, origin, time, process, exit.getPid(),
                        text.toString(), pairingToken, downloadCode));
                if (local != null) {
                    merged.add(local.file());
                }
            } catch (IOException | RuntimeException unavailable) {
                // Each system record is independent, including any local Java fallback.
            }
        }
    }

    @TargetApi(30)
    private static String platformTrace(ApplicationExitInfo exit) {
        try (InputStream input = exit.getTraceInputStream()) {
            if (input != null) {
                byte[] bytes = readBounded(input);
                if (exit.getReason() == ApplicationExitInfo.REASON_CRASH_NATIVE) {
                    String nativeTrace = NativeTombstone.summarize(bytes);
                    if (!nativeTrace.trim().isEmpty()) {
                        return nativeTrace + (bytes.length == TRACE_BYTES ? TRACE_LIMIT : "");
                    }
                } else {
                    String trace = onlyProcessTrace(new String(bytes, StandardCharsets.UTF_8),
                            exit.getPid(), exit.getProcessName());
                    if (!trace.trim().isEmpty()) {
                        return trace + (bytes.length == TRACE_BYTES ? TRACE_LIMIT : "");
                    }
                }
            }
        } catch (IOException | RuntimeException unavailable) {
            // Android may expire traces independently of their exit records.
        }
        return "系统未保留可读取的跟踪。\n";
    }

    static String onlyProcessTrace(String trace, int pid, String process) {
        if (trace.indexOf('\0') >= 0) {
            return "";
        }
        Matcher headers = PROCESS_HEADER.matcher(trace);
        if (!headers.find()) {
            return "";
        }
        String expectedPid = Integer.toString(pid);
        do {
            if (expectedPid.equals(headers.group(1))) {
                int start = headers.start();
                int end = headers.find() ? headers.start() : trace.length();
                Matcher footer = PROCESS_END.matcher(trace).region(start, end);
                if (footer.find()) {
                    if (!expectedPid.equals(footer.group(1))) {
                        return "";
                    }
                    end = footer.end();
                }
                String section = trace.substring(start, end).trim();
                Matcher command = COMMAND_LINE.matcher(section);
                if (command.find() && (!process.equals(command.group(1).trim()) || command.find())) {
                    return "";
                }
                return section + "\n";
            }
        } while (headers.find());
        return "";
    }

    private static JavaCrash matchJavaCrash(Context context, List<JavaCrash> crashes, Set<File> merged,
                                            long timestamp, int pid, String process) {
        JavaCrash best = null;
        long closest = MERGE_WINDOW_MS + 1;
        for (JavaCrash crash : crashes) {
            long distance = Math.abs(timestamp - crash.time());
            if (crash.pid() == pid && distance < closest && !merged.contains(crash.file())) {
                try {
                    if (process.equals(javaTrace(context, crash).process())) {
                        closest = distance;
                        best = crash;
                    }
                } catch (IOException | RuntimeException unavailable) {
                    // A system record can still be shown on its own.
                }
            }
        }
        return best;
    }

    private static List<JavaCrash> recentJavaCrashes(File directory, long now) {
        List<JavaCrash> crashes = new ArrayList<>();
        File[] files = directory.listFiles();
        if (files == null) {
            return crashes;
        }
        for (File file : files) {
            Matcher match = JAVA_FILE.matcher(file.getName());
            if (match.matches()) {
                try {
                    long time = Long.parseLong(match.group(1));
                    if (recent(time, now)) {
                        crashes.add(new JavaCrash(file, time, Integer.parseInt(match.group(2))));
                    } else if (time < now - DAY_MS) {
                        file.delete();
                    }
                } catch (NumberFormatException invalid) {
                    // Ignore filenames outside the import format.
                }
            } else if (file.lastModified() < now - DAY_MS) {
                file.delete();
            }
        }
        crashes.sort(Comparator.comparingLong(JavaCrash::time).reversed());
        return crashes;
    }

    private static JavaTrace javaTrace(Context context, JavaCrash crash) throws IOException {
        try (InputStream input = new FileInputStream(crash.file())) {
            byte[] bytes = readBounded(input);
            String contents = new String(bytes, StandardCharsets.UTF_8);
            int split = contents.indexOf('\n');
            if (split < 0) {
                throw new IOException("Missing process name in crash record");
            }
            String trace = contents.substring(split + 1) + (bytes.length == TRACE_BYTES ? TRACE_LIMIT : "");
            return new JavaTrace(ownProcess(context, contents.substring(0, split)), trace);
        }
    }

    private static boolean recent(long timestamp, long now) {
        return timestamp >= now - DAY_MS && timestamp <= now;
    }

    private static boolean isOwnProcess(Context context, String process) {
        String own = context.getPackageName();
        return process != null && (process.equals(own) || process.startsWith(own + ":"));
    }

    private static String ownProcess(Context context, String process) {
        return isOwnProcess(context, process) ? process : context.getPackageName();
    }

    private static File javaDirectory(Context context) {
        return new File(context.getFilesDir(), "diagnostic-java-crashes");
    }

    private static Report writeReport(File destination, String kind, String origin, long time, String process,
                                      int pid, String text, String pairingToken, String downloadCode) throws IOException {
        String filename = kind + "-" + REPORT_TIME.format(Instant.ofEpochMilli(time)) + "Z-"
                + pid + "-" + origin + ".txt";
        File file = new File(destination, filename);
        // Keep the first export stable even if Android expires its attached system trace later.
        if (file.length() == 0) {
            writeAtomic(file, bounded(redact(text, pairingToken, downloadCode)));
        }
        return new Report(file, time, kind, process);
    }

    private static String header(String kind, String category, long time, String process, int pid) {
        return "截屏快传 Android 诊断\n"
                + "类型    " + kind + " · " + category + "\n"
                + "时间    " + Instant.ofEpochMilli(time) + "\n"
                + "进程    " + process + " (PID " + pid + ")\n"
                + "Android API    " + Build.VERSION.SDK_INT + "\n";
    }

    private static void pruneReports(File directory, long now) {
        File[] files = directory.listFiles();
        if (files != null) {
            for (File file : files) {
                if (file.lastModified() < now - 2 * DAY_MS) {
                    file.delete();
                }
            }
        }
    }

    private static void writeAtomic(File file, String contents) throws IOException {
        AtomicFile atomic = new AtomicFile(file);
        FileOutputStream output = atomic.startWrite();
        try {
            output.write(contents.getBytes(StandardCharsets.UTF_8));
            atomic.finishWrite(output);
        } catch (IOException | RuntimeException failure) {
            atomic.failWrite(output);
            throw failure;
        }
    }

    private static byte[] readBounded(InputStream input) throws IOException {
        ByteArrayOutputStream result = new ByteArrayOutputStream(8192);
        byte[] buffer = new byte[8192];
        while (result.size() < TRACE_BYTES) {
            int count = input.read(buffer, 0, Math.min(buffer.length, TRACE_BYTES - result.size()));
            if (count <= 0) {
                break;
            }
            result.write(buffer, 0, count);
        }
        return result.toByteArray();
    }

    static String redact(String text, String pairingToken, String downloadCode) {
        if (pairingToken != null && pairingToken.length() >= 8) {
            text = text.replace(pairingToken, HIDDEN);
        }
        if (downloadCode != null && downloadCode.length() >= 8) {
            text = text.replace(downloadCode, HIDDEN);
        }
        text = BEARER.matcher(text).replaceAll("$1" + HIDDEN);
        text = CREDENTIAL_FIELD.matcher(text).replaceAll("$1" + HIDDEN);
        text = QR_CODE.matcher(text).replaceAll("$1" + HIDDEN);
        text = URL_PASSWORD.matcher(text).replaceAll("$1" + HIDDEN + "$2");
        return RELAY_SECRET.matcher(text).replaceAll(HIDDEN);
    }

    private static String bounded(String text) {
        return text.length() <= REPORT_CHARS ? text : text.substring(0, REPORT_CHARS) + TRACE_LIMIT;
    }

    private static final class LimitedWriter extends Writer {
        private final StringBuilder contents = new StringBuilder();
        private boolean limited;

        @Override
        public void write(char[] buffer, int start, int length) {
            int count = Math.min(length, REPORT_CHARS - contents.length());
            contents.append(buffer, start, count);
            limited |= count < length;
        }

        @Override
        public void write(String text, int start, int length) {
            int count = Math.min(length, REPORT_CHARS - contents.length());
            contents.append(text, start, start + count);
            limited |= count < length;
        }

        @Override
        public void flush() {}

        @Override
        public void close() {}

        @Override
        public String toString() {
            return contents + (limited ? TRACE_LIMIT : "");
        }
    }
}
