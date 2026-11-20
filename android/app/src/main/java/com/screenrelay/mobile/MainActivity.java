package com.screenrelay.mobile;

import android.Manifest;
import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.text.TextUtils;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.IOException;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private static final int MEDIA_PERMISSION_REQUEST = 1;
    private static final int NOTIFICATION_PERMISSION_REQUEST = 2;
    private static final int BLUE = Color.rgb(37, 88, 221);
    private static final int INK = Color.rgb(23, 36, 62);
    private static final int SECONDARY = Color.rgb(72, 88, 113);
    private static final int BORDER = Color.rgb(218, 226, 240);

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService connectionTest = Executors.newSingleThreadExecutor();
    private final Runnable refresh = this::refreshDashboard;
    private Settings settings;
    private Settings.Configuration awaitingPermission;
    private EditText address;
    private EditText secret;
    private TextView status;
    private TextView tracking;
    private TextView statistics;
    private TextView feedback;
    private Button activate;
    private Button pause;
    private Button retry;
    private Button test;

    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);
        settings = new Settings(this);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        setContentView(makeScreen());
        Settings.Configuration saved = settings.configuration();
        address.setText(saved.origin());
        secret.setText(saved.token());
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (settings.isEnabled() && Settings.hasMediaAccess(this) && !WatchService.isRunning()) {
            ensureRunning();
        }
        refreshDashboard();
    }

    @Override
    protected void onPause() {
        main.removeCallbacks(refresh);
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        main.removeCallbacksAndMessages(null);
        connectionTest.shutdownNow();
        super.onDestroy();
    }

    private View makeScreen() {
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setClipToPadding(false);

        LinearLayout page = column();
        page.setFocusableInTouchMode(true);
        scroll.addView(page);
        int margin = dp(24);
        scroll.setOnApplyWindowInsetsListener((view, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                Insets safe = insets.getInsets(WindowInsets.Type.systemBars()
                        | WindowInsets.Type.displayCutout() | WindowInsets.Type.ime());
                view.setPadding(margin + safe.left, margin + safe.top,
                        margin + safe.right, margin + safe.bottom);
            } else {
                view.setPadding(margin + insets.getSystemWindowInsetLeft(),
                        margin + insets.getSystemWindowInsetTop(),
                        margin + insets.getSystemWindowInsetRight(),
                        margin + insets.getSystemWindowInsetBottom());
            }
            return insets;
        });

        TextView title = text("截屏快传", 32, INK, true);
        add(page, title, 0);
        add(page, text("把手机新保存的截图和录屏发送到电脑。", 15, SECONDARY, false), 8);

        LinearLayout dashboard = card();
        add(page, dashboard, 24);
        status = text("", 17, INK, true);
        status.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        add(dashboard, status, 0);
        tracking = text("", 14, SECONDARY, false);
        add(dashboard, tracking, 6);
        statistics = text("", 14, SECONDARY, false);
        add(dashboard, statistics, 10);

        LinearLayout pairing = card();
        add(page, pairing, 16);
        add(pairing, text("配对电脑", 19, INK, true), 0);
        add(pairing, text("输入电脑接收端显示的地址和密钥。", 14, SECONDARY, false), 8);

        address = field("http://192.168.1.10:8765",
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        labelField(pairing, "电脑地址", address);
        secret = field("电脑上的配对密钥",
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        labelField(pairing, "配对密钥", secret);

        activate = button("开始自动上传", true);
        activate.setOnClickListener(view -> onActivate());
        add(pairing, activate, 18);

        test = button("测试连接", false);
        test.setOnClickListener(view -> onTest());
        add(pairing, test, 8);
        feedback = text("", 14, SECONDARY, false);
        feedback.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        feedback.setVisibility(View.GONE);
        add(pairing, feedback, 8);

        pause = button("暂停自动上传", false);
        pause.setOnClickListener(view -> onPauseUpload());
        add(page, pause, 12);
        retry = button("重试待上传和失败的文件", false);
        retry.setOnClickListener(view -> {
            SyncEngine.retry(this);
            ensureRunning();
            showFeedback("已安排重试。");
        });
        add(page, retry, 6);

        add(page, text("请让手机和电脑连接同一可信 Wi-Fi，并保持电脑接收端运行。系统限制后台任务时，上传可能延迟。",
                13, SECONDARY, false), 16);
        return scroll;
    }

    private void onActivate() {
        Settings.Configuration configuration = readConfiguration();
        if (configuration == null) {
            return;
        }
        if (!Settings.hasMediaAccess(this)) {
            awaitingPermission = configuration;
            requestPermissions(Settings.mediaPermissions(), MEDIA_PERMISSION_REQUEST);
        } else {
            enable(configuration);
        }
    }

    private void enable(Settings.Configuration configuration) {
        settings.enable(configuration);
        settings.setStatus("正在检查新的截屏和录屏。");
        SyncEngine.retry(this);
        ensureRunning();
        showFeedback("自动上传已开启。");
        if (Build.VERSION.SDK_INT >= 33
                && !Settings.granted(this, Manifest.permission.POST_NOTIFICATIONS)
                && !getPreferences(MODE_PRIVATE).getBoolean("askedNotifications", false)) {
            getPreferences(MODE_PRIVATE).edit().putBoolean("askedNotifications", true).apply();
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS},
                    NOTIFICATION_PERMISSION_REQUEST);
        }
        refreshDashboard();
    }

    private void ensureRunning() {
        boolean scheduled = SyncJob.ensureScheduled(this);
        try {
            startForegroundService(new Intent(this, WatchService.class));
        } catch (IllegalStateException limited) {
            settings.setStatus(scheduled ? "系统将在后台继续同步，上传可能延迟。"
                    : "系统暂未安排自动上传，请稍后重新开启。");
        }
    }

    private void onPauseUpload() {
        settings.disable();
        SyncJob.cancel(this);
        stopService(new Intent(this, WatchService.class));
        showFeedback("自动上传已暂停。恢复后可补传期间保存的截屏和录屏。");
        refreshDashboard();
    }

    private void onTest() {
        Settings.Configuration configuration = readConfiguration();
        if (configuration == null) {
            return;
        }
        test.setEnabled(false);
        showFeedback("正在连接电脑…");
        connectionTest.execute(() -> {
            String result;
            try {
                result = UploadClient.checkConnection(configuration)
                        ? "已连接电脑。首次上传时会验证配对密钥。"
                        : "这个地址的接收端未正常响应。";
            } catch (IOException disconnected) {
                result = "无法连接电脑。请确认地址、Wi-Fi 和接收端运行状态。";
            }
            String message = result;
            main.post(() -> {
                if (!isDestroyed()) {
                    showFeedback(message);
                    test.setEnabled(true);
                }
            });
        });
    }

    private Settings.Configuration readConfiguration() {
        try {
            return Settings.Configuration.fromInput(address.getText(), secret.getText());
        } catch (IllegalArgumentException invalid) {
            showFeedback(invalid.getMessage());
            return null;
        }
    }

    private void showFeedback(String message) {
        feedback.setText(message);
        feedback.setVisibility(View.VISIBLE);
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(code, permissions, results);
        if (code == MEDIA_PERMISSION_REQUEST) {
            Settings.Configuration requested = awaitingPermission;
            awaitingPermission = null;
            if (!Settings.hasMediaAccess(this)) {
                showFeedback("请在系统设置中允许访问所有照片和视频，以便发现新截屏和录屏。");
            } else if (requested != null) {
                enable(requested);
            }
        }
    }

    private void refreshDashboard() {
        main.removeCallbacks(refresh);
        boolean enabled = settings.isEnabled();
        boolean running = WatchService.isRunning();
        boolean authorized = Settings.hasMediaAccess(this);
        String detail = settings.status();
        if (!enabled) {
            detail = settings.firstEnabledAt() < 0 ? "等待配对" : "自动上传已暂停";
        } else if (!authorized) {
            detail = "需要相册访问权限";
        } else if (detail.isEmpty()) {
            detail = running ? "正在监测截屏和录屏" : "等待系统安排同步";
        }
        if (!TextUtils.equals(status.getText(), detail)) {
            status.setText(detail);
        }
        tracking.setVisibility(enabled && authorized ? View.VISIBLE : View.GONE);
        tracking.setText(running ? "实时监测已开启" : "由系统安排后台同步，上传可能延迟");
        SyncStore.Counts counts = SyncStore.get(this).counts();
        statistics.setText(String.format(Locale.SIMPLIFIED_CHINESE,
                "待上传 %d   ·   已上传 %d   ·   失败 %d",
                counts.waiting(), counts.uploaded(), counts.failed()));
        activate.setText(enabled ? "保存并同步" : "开始自动上传");
        pause.setVisibility(enabled ? View.VISIBLE : View.GONE);
        retry.setVisibility(enabled && (counts.failed() > 0 || counts.waiting() > 0) ? View.VISIBLE : View.GONE);
        main.postDelayed(refresh, 3_000);
    }

    private LinearLayout column() {
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        return layout;
    }

    private LinearLayout card() {
        LinearLayout card = column();
        card.setBackground(rounded(Color.WHITE, BORDER, 17));
        int padding = dp(18);
        card.setPadding(padding, padding, padding, padding);
        return card;
    }

    private TextView text(String value, int size, int color, boolean bold) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(size);
        view.setTextColor(color);
        if (bold) {
            view.setTypeface(view.getTypeface(), Typeface.BOLD);
        }
        return view;
    }

    private EditText field(String hint, int inputType) {
        EditText input = new EditText(this);
        input.setId(View.generateViewId());
        input.setSingleLine();
        input.setInputType(inputType);
        input.setHint(hint);
        input.setTextSize(15);
        input.setTextColor(INK);
        input.setHintTextColor(SECONDARY);
        input.setPadding(dp(12), dp(10), dp(12), dp(10));
        input.setMinHeight(dp(48));
        input.setBackground(rounded(Color.WHITE, BORDER, 9));
        input.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
        return input;
    }

    private void labelField(LinearLayout parent, String label, EditText input) {
        TextView caption = text(label, 14, INK, true);
        caption.setLabelFor(input.getId());
        add(parent, caption, 16);
        add(parent, input, 6);
    }

    private Button button(String label, boolean primary) {
        Button button = new Button(this);
        button.setText(label);
        button.setAllCaps(false);
        button.setTextSize(15);
        button.setTextColor(primary ? Color.WHITE : BLUE);
        button.setMinimumHeight(dp(48));
        button.setBackground(rounded(primary ? BLUE : Color.WHITE, primary ? BLUE : BORDER, 10));
        return button;
    }

    private GradientDrawable rounded(int fill, int stroke, int radius) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(fill);
        drawable.setStroke(dp(1), stroke);
        drawable.setCornerRadius(dp(radius));
        return drawable;
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
