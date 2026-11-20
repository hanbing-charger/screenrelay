package com.screenrelay.mobile;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.format.DateFormat;
import android.util.Base64;
import android.view.View;
import android.view.WindowInsets;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Date;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class DiagnosticActivity extends Activity {
    private static final int INK = Color.rgb(23, 36, 62);
    private static final int SECONDARY = Color.rgb(72, 88, 113);
    private static final int BORDER = Color.rgb(218, 226, 240);
    private static final Object RECEIPTS_LOCK = new Object();

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService work = Executors.newSingleThreadExecutor();
    private final Map<DiagnosticReports.Report, CheckBox> rows = new LinkedHashMap<>();
    private final Set<String> sent = new HashSet<>();
    private final Set<String> failed = new HashSet<>();
    private Context application;
    private Settings.Configuration destination;
    private SharedPreferences receipts;
    private String destinationKey;
    private java.text.DateFormat dateFormat;
    private java.text.DateFormat timeFormat;
    private LinearLayout reportList;
    private TextView listStatus;
    private TextView sendStatus;
    private Button selectAll;
    private Button send;
    private boolean sending;

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        application = getApplicationContext();
        destination = savedDestination();
        receipts = application.getSharedPreferences("diagnostic-deliveries", Context.MODE_PRIVATE);
        destinationKey = destination == null ? "" : destinationKey(destination);
        dateFormat = DateFormat.getMediumDateFormat(this);
        timeFormat = DateFormat.getTimeFormat(this);
        setContentView(makeScreen());

        List<String> selection = state == null ? null : state.getStringArrayList("selected-reports");
        loadReports(selection == null ? Collections.emptySet() : new HashSet<>(selection));
    }

    @Override
    protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        ArrayList<String> selection = new ArrayList<>();
        for (DiagnosticReports.Report report : checkedReports()) {
            selection.add(report.file.getName());
        }
        state.putStringArrayList("selected-reports", selection);
    }

    @Override
    protected void onDestroy() {
        main.removeCallbacksAndMessages(null);
        work.shutdownNow();
        super.onDestroy();
    }

    private View makeScreen() {
        LinearLayout root = column();
        int margin = dp(20);
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                Insets safe = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                view.setPadding(margin + safe.left, margin + safe.top,
                        margin + safe.right, margin + safe.bottom);
            } else {
                view.setPadding(margin + insets.getSystemWindowInsetLeft(),
                        margin + insets.getSystemWindowInsetTop(), margin + insets.getSystemWindowInsetRight(),
                        margin + insets.getSystemWindowInsetBottom());
            }
            return insets;
        });

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        LinearLayout page = column();
        scroll.addView(page);
        root.addView(scroll, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1));

        Button back = button("返回");
        back.setOnClickListener(view -> finish());
        page.addView(back, new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT));
        TextView title = text("诊断日志", 28, INK);
        title.setTypeface(title.getTypeface(), Typeface.BOLD);
        title.setAccessibilityHeading(true);
        add(page, title, 10);
        add(page, text("这里显示截屏快传最近 24 小时的崩溃（Crash）和无响应（ANR）记录。勾选 TXT 报告后，可发送到已配对电脑。",
                15, SECONDARY), 8);
        if (Build.VERSION.SDK_INT == 29) {
            add(page, text("Android 10 可记录应用自身的 Java 崩溃。系统 ANR 记录需要 Android 11 或更高版本。",
                    14, SECONDARY), 8);
        }

        listStatus = text("正在生成 TXT 报告…", 15, SECONDARY);
        listStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        add(page, listStatus, 14);
        selectAll = button("全选未发送");
        selectAll.setVisibility(View.GONE);
        selectAll.setOnClickListener(view -> toggleAll());
        add(page, selectAll, 8);
        reportList = column();
        add(page, reportList, 6);

        sendStatus = text(destination == null ? "请先在首页配对电脑。" : "", 14, SECONDARY);
        sendStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        sendStatus.setVisibility(destination == null ? View.VISIBLE : View.GONE);
        add(root, sendStatus, 8);
        send = button("发送到电脑");
        send.setEnabled(false);
        send.setOnClickListener(view -> sendSelected());
        add(root, send, 8);
        return root;
    }

    private void loadReports(Set<String> selection) {
        work.execute(() -> {
            final List<DiagnosticReports.Report> reports;
            try {
                reports = DiagnosticReports.load(application);
            } catch (Exception unavailable) {
                post(() -> listStatus.setText("无法读取诊断记录。请返回后重新打开诊断日志。"));
                return;
            }
            Set<String> delivered = loadReceipts(reports);
            post(() -> showReports(reports, selection, delivered));
        });
    }

    private void showReports(List<DiagnosticReports.Report> reports, Set<String> selection, Set<String> delivered) {
        sent.addAll(delivered);
        if (reports.isEmpty()) {
            listStatus.setText("最近 24 小时没有可用的诊断记录。");
            return;
        }
        listStatus.setText("已生成 " + reports.size() + " 份 TXT 报告");
        selectAll.setVisibility(View.VISIBLE);
        for (DiagnosticReports.Report report : reports) {
            CheckBox choice = new CheckBox(this);
            choice.setTextSize(15);
            choice.setMinHeight(dp(62));
            choice.setPadding(dp(12), dp(10), dp(12), dp(10));
            GradientDrawable card = new GradientDrawable();
            card.setColor(Color.WHITE);
            card.setStroke(dp(1), BORDER);
            card.setCornerRadius(dp(12));
            choice.setBackground(card);
            choice.setChecked(selection.contains(report.file.getName()) && !sent.contains(report.file.getName()));
            choice.setOnCheckedChangeListener((button, checked) -> updateControls());
            rows.put(report, choice);
            showReport(report, choice);
            add(reportList, choice, 8);
        }
        updateControls();
    }

    private void showReport(DiagnosticReports.Report report, CheckBox choice) {
        String name = report.file.getName();
        Date date = new Date(report.timestamp);
        String kind = "ANR".equals(report.kind) ? "无响应（ANR）" : "崩溃（Crash）";
        String state = failed.contains(name) ? " · 发送失败" : sent.contains(name) ? " · 已发送" : "";
        String process = report.processName == null || report.processName.isEmpty() ? "截屏快传" : report.processName;
        choice.setText(kind + state + "\n" + dateFormat.format(date) + " " + timeFormat.format(date)
                + "\n" + process + "\n" + name);
        choice.setEnabled(!sending);
    }

    private List<DiagnosticReports.Report> checkedReports() {
        List<DiagnosticReports.Report> selection = new ArrayList<>();
        for (Map.Entry<DiagnosticReports.Report, CheckBox> row : rows.entrySet()) {
            if (row.getValue().isChecked()) {
                selection.add(row.getKey());
            }
        }
        return selection;
    }

    private void updateControls() {
        int available = rows.size() - sent.size();
        List<DiagnosticReports.Report> selection = checkedReports();
        int selected = selection.size();
        int newReportsSelected = unsentCount(selection);
        selectAll.setEnabled(!sending && (available > 0 || selected > 0));
        selectAll.setText(selected > 0 && newReportsSelected == available ? "取消全选" : "全选未发送");
        send.setEnabled(!sending && destination != null && selected > 0);
        send.setText(sending ? "正在发送…" : selected == 0 ? "发送到电脑" : "发送到电脑（" + selected + "）");
    }

    private void toggleAll() {
        boolean selectNewReports = unsentCount(checkedReports()) < rows.size() - sent.size();
        for (Map.Entry<DiagnosticReports.Report, CheckBox> row : rows.entrySet()) {
            if (!selectNewReports || !sent.contains(row.getKey().file.getName())) {
                row.getValue().setChecked(selectNewReports);
            }
        }
        updateControls();
    }

    private int unsentCount(List<DiagnosticReports.Report> selection) {
        int count = 0;
        for (DiagnosticReports.Report report : selection) {
            if (!sent.contains(report.file.getName())) count++;
        }
        return count;
    }

    private void sendSelected() {
        List<DiagnosticReports.Report> selection = checkedReports();
        if (sending || destination == null || selection.isEmpty()) return;
        sending = true;
        rows.forEach(this::showReport);
        updateControls();
        showSendStatus("正在发送 " + selection.size() + " 份报告…");
        work.execute(() -> sendReports(selection));
    }

    private void sendReports(List<DiagnosticReports.Report> selection) {
        int succeeded = 0;
        String firstError = "";
        for (DiagnosticReports.Report report : selection) {
            if (Thread.currentThread().isInterrupted()) return;
            String name = report.file.getName();
            try {
                if (!report.file.isFile()) throw new IOException("报告已过期。请重新打开诊断日志。");
                UploadClient.uploadDiagnostic(application, destination, report.file, report.timestamp);
                saveReceipt(name);
                succeeded++;
                post(() -> finishReport(report, true));
            } catch (IOException unavailable) {
                if (firstError.isEmpty()) firstError = unavailable.getMessage() == null
                        ? "发送报告时出错。" : unavailable.getMessage();
                post(() -> finishReport(report, false));
            }
        }
        int failures = selection.size() - succeeded;
        String summary = "已发送 " + succeeded + " 份报告。";
        if (failures > 0) {
            summary += "失败 " + failures + " 份，失败项已保留勾选。" + firstError;
        }
        String message = summary;
        post(() -> {
            sending = false;
            rows.forEach(this::showReport);
            updateControls();
            showSendStatus(message);
        });
    }

    private void finishReport(DiagnosticReports.Report report, boolean delivered) {
        String name = report.file.getName();
        CheckBox choice = rows.get(report);
        if (delivered) {
            sent.add(name);
            failed.remove(name);
            choice.setChecked(false);
        } else {
            failed.add(name);
        }
        showReport(report, choice);
    }

    private void showSendStatus(String value) {
        sendStatus.setText(value);
        sendStatus.setVisibility(View.VISIBLE);
    }

    private Settings.Configuration savedDestination() {
        Settings.Configuration saved = new Settings(application).configuration();
        try {
            return Settings.Configuration.fromInput(saved.origin(), saved.token());
        } catch (IllegalArgumentException invalid) {
            return null;
        }
    }

    private Set<String> loadReceipts(List<DiagnosticReports.Report> reports) {
        if (destination == null) return Collections.emptySet();
        Set<String> names = new HashSet<>();
        for (DiagnosticReports.Report report : reports) names.add(report.file.getName());
        synchronized (RECEIPTS_LOCK) {
            Set<String> delivered = new HashSet<>(receipts.getStringSet(destinationKey, Collections.emptySet()));
            if (delivered.retainAll(names)) receipts.edit().putStringSet(destinationKey, delivered).apply();
            return delivered;
        }
    }

    private void saveReceipt(String name) {
        synchronized (RECEIPTS_LOCK) {
            Set<String> delivered = new HashSet<>(receipts.getStringSet(destinationKey, Collections.emptySet()));
            if (delivered.add(name)) receipts.edit().putStringSet(destinationKey, delivered).apply();
        }
    }

    private static String destinationKey(Settings.Configuration configuration) {
        byte[] peer = (configuration.origin() + "\n" + configuration.token()).getBytes(StandardCharsets.UTF_8);
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(peer);
            return Base64.encodeToString(digest, Base64.NO_WRAP);
        } catch (NoSuchAlgorithmException impossible) {
            throw new IllegalStateException(impossible);
        }
    }

    private void post(Runnable update) {
        main.post(() -> {
            if (!isDestroyed() && !isFinishing()) update.run();
        });
    }

    private LinearLayout column() {
        LinearLayout view = new LinearLayout(this);
        view.setOrientation(LinearLayout.VERTICAL);
        return view;
    }

    private TextView text(String value, int size, int color) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(size);
        view.setTextColor(color);
        return view;
    }

    private Button button(String label) {
        Button view = new Button(this);
        view.setText(label);
        view.setTextSize(15);
        view.setAllCaps(false);
        view.setMinHeight(dp(48));
        return view;
    }

    private void add(LinearLayout parent, View view, int top) {
        LinearLayout.LayoutParams layout = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT);
        layout.topMargin = dp(top);
        parent.addView(view, layout);
    }

    private int dp(int size) {
        return Math.round(size * getResources().getDisplayMetrics().density);
    }
}
