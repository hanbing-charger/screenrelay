package com.screenrelay.mobile;

import android.Manifest;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.text.TextUtils;
import android.text.format.Formatter;
import android.view.View;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;

import com.journeyapps.barcodescanner.ScanIntentResult;
import com.journeyapps.barcodescanner.ScanOptions;

import java.io.IOException;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.Locale;
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private static final int MEDIA_PERMISSION_REQUEST = 1;
    private static final int NOTIFICATION_PERMISSION_REQUEST = 2;
    private static final int CAMERA_PERMISSION_REQUEST = 3;
    private static final int QR_SCAN_REQUEST = 4;
    private static final int DOWNLOAD_CAMERA_PERMISSION_REQUEST = 5;
    private static final int DOWNLOAD_SCAN_REQUEST = 6;
    private static final int CHOOSE_IMAGES_REQUEST = 7;
    private static final int BLUE = Color.rgb(37, 88, 221);
    private static final int INK = Color.rgb(23, 36, 62);
    private static final int SECONDARY = Color.rgb(72, 88, 113);
    private static final int BORDER = Color.rgb(218, 226, 240);

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService connectionTest = Executors.newSingleThreadExecutor();
    private final Runnable refresh = this::refreshDashboard;
    private final Runnable refreshDownload = this::refreshDownloadStatus;
    private final Runnable refreshImages = this::refreshImageUploads;
    private Settings settings;
    private IncomingDownloads downloads;
    private ManualImageUploads imageUploads;
    private Settings.Configuration awaitingPermission;
    private EditText address;
    private EditText secret;
    private TextView status;
    private TextView tracking;
    private TextView statistics;
    private TextView feedback;
    private Button activate;
    private Button scan;
    private Button pause;
    private Button retry;
    private Button test;
    private Button scanDownload;
    private Button resumeDownload;
    private Button discardDownload;
    private TextView downloadStatus;
    private TextView downloadAmount;
    private ProgressBar downloadProgress;
    private String downloadFeedback = "";
    private Button chooseImages;
    private Button retryImages;
    private Button discardImages;
    private TextView imageStatus;
    private String imageFeedback = "";
    private boolean pairingBusy;

    @Override
    public void onCreate(Bundle state) {
        super.onCreate(state);
        settings = new Settings(this);
        downloads = IncomingDownloads.get(this);
        imageUploads = ManualImageUploads.get(this);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        setContentView(makeScreen());
        Settings.Configuration saved = settings.configuration();
        address.setText(saved.origin());
        secret.setText(saved.token());
        downloads.restoreOnce();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (settings.isEnabled() && Settings.hasMediaAccess(this) && !WatchService.isRunning()) {
            ensureRunning();
        }
        refreshDashboard();
        refreshDownloadStatus();
        refreshImageUploads();
    }

    @Override
    protected void onPause() {
        main.removeCallbacks(refresh);
        main.removeCallbacks(refreshDownload);
        main.removeCallbacks(refreshImages);
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

        add(page, makeImageUploadCard(), 16);
        add(page, makeDownloadCard(), 16);

        LinearLayout pairing = card();
        add(page, pairing, 16);
        add(pairing, text("配对电脑", 19, INK, true), 0);
        scan = button("扫码配对", true);
        scan.setOnClickListener(view -> onScan(false));
        add(pairing, scan, 12);
        feedback = text("", 14, SECONDARY, false);
        feedback.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        feedback.setVisibility(View.GONE);
        add(pairing, feedback, 8);
        add(pairing, text("也可以手动填写电脑端显示的地址和密钥。", 14, SECONDARY, false), 12);

        address = field("http://192.168.1.10:8765",
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        labelField(pairing, "电脑地址", address);
        secret = field("电脑上的配对密钥",
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        labelField(pairing, "配对密钥", secret);

        activate = button("开始自动上传", false);
        activate.setOnClickListener(view -> onActivate());
        add(pairing, activate, 18);

        test = button("测试连接", false);
        test.setOnClickListener(view -> onTest());
        add(pairing, test, 8);

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

        Button diagnostics = button("诊断日志", false);
        diagnostics.setOnClickListener(view -> startActivity(new Intent(this, DiagnosticActivity.class)));
        add(page, diagnostics, 12);

        add(page, text("请让手机和电脑连接同一可信 Wi-Fi，并保持电脑接收端运行。系统限制后台任务时，上传可能延迟。",
                13, SECONDARY, false), 16);
        return scroll;
    }

    private void onActivate() {
        Settings.Configuration configuration = readConfiguration();
        if (configuration != null) {
            activate(configuration);
        }
    }

    private View makeImageUploadCard() {
        LinearLayout images = card();
        chooseImages = button("选择图片上传", true);
        chooseImages.setOnClickListener(view -> openImagePicker());
        add(images, chooseImages, 0);
        imageStatus = text("", 14, SECONDARY, false);
        imageStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        add(images, imageStatus, 8);
        retryImages = button("继续上传图片", false);
        retryImages.setOnClickListener(view -> {
            Settings.Configuration configuration = imageUploadConfiguration();
            if (configuration != null) {
                imageFeedback = "";
                imageUploads.resume(configuration);
                refreshImageUploads();
            }
        });
        add(images, retryImages, 8);
        discardImages = button("清除暂存图片", false);
        discardImages.setOnClickListener(view -> {
            imageFeedback = "";
            imageUploads.discard();
            refreshImageUploads();
        });
        add(images, discardImages, 6);
        return images;
    }

    private void refreshImageUploads() {
        main.removeCallbacks(refreshImages);
        ManualImageUploads.State uploads = imageUploads.state();
        String message = imageFeedback.isEmpty() ? uploads.message() : imageFeedback;
        if (!TextUtils.equals(message, imageStatus.getText())) {
            imageStatus.setText(message);
        }
        imageStatus.setVisibility(message.isEmpty() ? View.GONE : View.VISIBLE);
        chooseImages.setEnabled(!pairingBusy && !uploads.busy() && uploads.pending() == 0);
        retryImages.setVisibility(!uploads.busy() && uploads.pending() > 0 ? View.VISIBLE : View.GONE);
        retryImages.setEnabled(!pairingBusy);
        discardImages.setVisibility(!uploads.busy() && uploads.pending() > 0 ? View.VISIBLE : View.GONE);
        if (uploads.busy()) {
            main.postDelayed(refreshImages, 250);
        }
    }

    private Settings.Configuration imageUploadConfiguration() {
        Settings.Configuration configuration = settings.configuration();
        if (!configuration.origin().isEmpty() && !configuration.token().isEmpty()) {
            return configuration;
        }
        try {
            configuration = Settings.Configuration.fromInput(address.getText(), secret.getText());
            settings.saveConfiguration(configuration);
            return configuration;
        } catch (IllegalArgumentException missingPairing) {
            imageFeedback = "请先在下方扫码配对，或填入电脑地址和配对密钥。";
            refreshImageUploads();
            return null;
        }
    }

    private void openImagePicker() {
        if (imageUploadConfiguration() == null) {
            return;
        }
        Intent picker = new Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("image/*")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        try {
            startActivityForResult(picker, CHOOSE_IMAGES_REQUEST);
        } catch (ActivityNotFoundException unavailable) {
            imageFeedback = "手机的系统文件选择器不可用。请启用系统文件应用后重试。";
            refreshImageUploads();
        }
    }

    private void uploadPickedImages(Intent data) {
        Settings.Configuration configuration = imageUploadConfiguration();
        if (configuration == null) {
            return;
        }
        Set<Uri> selected = new LinkedHashSet<>();
        ClipData images = data.getClipData();
        if (images != null) {
            for (int i = 0; i < images.getItemCount(); i++) {
                Uri uri = images.getItemAt(i).getUri();
                if (uri != null && "content".equals(uri.getScheme())) {
                    selected.add(uri);
                }
            }
        }
        Uri image = data.getData();
        if (image != null && "content".equals(image.getScheme())) {
            selected.add(image);
        }
        imageFeedback = selected.isEmpty() ? "未能打开所选图片，请在系统文件选择器中重新选择。" : "";
        imageUploads.start(new ArrayList<>(selected), configuration);
        refreshImageUploads();
    }

    private View makeDownloadCard() {
        LinearLayout download = card();
        scanDownload = button("扫码接收文件", true);
        scanDownload.setOnClickListener(view -> onScan(true));
        add(download, scanDownload, 0);
        downloadStatus = text("", 14, SECONDARY, false);
        downloadStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        add(download, downloadStatus, 8);
        downloadProgress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        downloadProgress.setMax(100);
        add(download, downloadProgress, 8);
        downloadAmount = text("", 13, SECONDARY, false);
        add(download, downloadAmount, 4);
        resumeDownload = button("继续接收", false);
        resumeDownload.setOnClickListener(view -> {
            downloadFeedback = "";
            downloads.resume();
            refreshDownloadStatus();
        });
        add(download, resumeDownload, 8);
        discardDownload = button("放弃本次接收", false);
        discardDownload.setOnClickListener(view -> {
            downloadFeedback = "";
            downloads.discard();
            refreshDownloadStatus();
        });
        add(download, discardDownload, 6);
        return download;
    }

    private void refreshDownloadStatus() {
        main.removeCallbacks(refreshDownload);
        IncomingDownloads.State download = downloads.state();
        String message = downloadFeedback.isEmpty() ? download.message() : downloadFeedback;
        if (!TextUtils.equals(message, downloadStatus.getText())) {
            downloadStatus.setText(message);
        }
        downloadStatus.setVisibility(message.isEmpty() ? View.GONE : View.VISIBLE);
        boolean showAmount = download.total() >= 0 && (download.running() || download.resumable());
        downloadProgress.setVisibility(showAmount ? View.VISIBLE : View.GONE);
        downloadAmount.setVisibility(showAmount ? View.VISIBLE : View.GONE);
        if (showAmount) {
            downloadProgress.setProgress(download.total() == 0 ? 100
                    : (int) (100.0 * download.received() / download.total()));
            downloadAmount.setText(Formatter.formatShortFileSize(this, download.received()) + " / "
                    + Formatter.formatShortFileSize(this, download.total()));
        }
        resumeDownload.setVisibility(download.resumable() ? View.VISIBLE : View.GONE);
        discardDownload.setVisibility(download.resumable() ? View.VISIBLE : View.GONE);
        scanDownload.setEnabled(!pairingBusy && !download.running() && !download.resumable());
        if (download.running()) {
            main.postDelayed(refreshDownload, 250);
        }
    }

    private void onScan(boolean download) {
        if (!getPackageManager().hasSystemFeature(PackageManager.FEATURE_CAMERA_ANY)) {
            showScannerFeedback(download, "这台手机没有可用的摄像头。");
            return;
        }
        if (Settings.granted(this, Manifest.permission.CAMERA)) {
            openScanner(download);
        } else {
            requestPermissions(new String[]{Manifest.permission.CAMERA},
                    download ? DOWNLOAD_CAMERA_PERMISSION_REQUEST : CAMERA_PERMISSION_REQUEST);
        }
    }

    private void showScannerFeedback(boolean download, String message) {
        if (download) {
            downloadFeedback = message;
            refreshDownloadStatus();
        } else {
            showFeedback(message + "也可以手动输入电脑地址和配对密钥。");
        }
    }

    private void openScanner(boolean download) {
        ScanOptions options = new ScanOptions()
                .setCaptureActivity(PairingScannerActivity.class)
                .setDesiredBarcodeFormats(ScanOptions.QR_CODE)
                .setOrientationLocked(false)
                .setBeepEnabled(false)
                .setPrompt(download ? "请扫描电脑上显示的文件下载二维码"
                        : "请扫描你电脑接收端显示的配对二维码");
        startActivityForResult(options.createScanIntent(this), download ? DOWNLOAD_SCAN_REQUEST : QR_SCAN_REQUEST);
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == CHOOSE_IMAGES_REQUEST) {
            if (resultCode == RESULT_OK && data != null) {
                uploadPickedImages(data);
            }
            return;
        }
        if ((requestCode != QR_SCAN_REQUEST && requestCode != DOWNLOAD_SCAN_REQUEST)
                || resultCode != RESULT_OK || data == null) {
            return;
        }
        String contents = ScanIntentResult.parseActivityResult(resultCode, data).getContents();
        if (requestCode == DOWNLOAD_SCAN_REQUEST) {
            try {
                ReceiverQr qr = ReceiverQr.read(contents, "download", "请扫描电脑显示的文件下载二维码。");
                downloadFeedback = "";
                downloads.start(new DownloadClient.Request(qr.origin(), qr.code()));
                refreshDownloadStatus();
            } catch (IllegalArgumentException invalid) {
                showScannerFeedback(true, invalid.getMessage());
            }
            return;
        }
        PairingClient.Request request;
        try {
            request = PairingClient.readQr(contents);
        } catch (IllegalArgumentException invalid) {
            showFeedback(invalid.getMessage());
            return;
        }

        setPairingBusy(true);
        showFeedback("正在与电脑配对…");
        connectionTest.execute(() -> {
            try {
                Settings.Configuration configuration = PairingClient.pair(
                        request, settings.installationId(), pairingDeviceName());
                main.post(() -> finishPairing(configuration, null));
            } catch (PairingClient.PairingFailure rejected) {
                main.post(() -> finishPairing(null, rejected.getMessage()));
            } catch (IOException disconnected) {
                main.post(() -> finishPairing(null, "无法完成配对。请确认手机和电脑连接同一 Wi-Fi。"));
            }
        });
    }

    private static String pairingDeviceName() {
        String label = Build.MODEL.replaceAll("\\p{Cntrl}", "").trim();
        if (label.isEmpty() || Build.UNKNOWN.equalsIgnoreCase(label)) {
            return "Android 手机";
        }
        if (label.codePointCount(0, label.length()) > 80) {
            return label.substring(0, label.offsetByCodePoints(0, 80));
        }
        return label;
    }

    private void setPairingBusy(boolean busy) {
        pairingBusy = busy;
        for (View control : new View[]{scan, activate, test, pause, retry, address, secret}) {
            control.setEnabled(!busy);
        }
        refreshDownloadStatus();
        refreshImageUploads();
    }

    private void finishPairing(Settings.Configuration configuration, String error) {
        if (isDestroyed()) {
            return;
        }
        setPairingBusy(false);
        if (configuration == null) {
            showFeedback(error);
            return;
        }
        address.setText(configuration.origin());
        secret.setText(configuration.token());
        if (!Settings.hasMediaAccess(this)) {
            showFeedback("已配对电脑，请授权访问照片和视频后开启自动上传。");
        }
        activate(configuration);
    }

    private void activate(Settings.Configuration configuration) {
        if (!Settings.hasMediaAccess(this)) {
            settings.saveConfiguration(configuration);
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
        scan.setEnabled(false);
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
                    scan.setEnabled(true);
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
        feedback.post(() -> feedback.requestRectangleOnScreen(
                new Rect(0, 0, feedback.getWidth(), feedback.getHeight())));
    }

    @Override
    public void onRequestPermissionsResult(int code, String[] permissions, int[] results) {
        super.onRequestPermissionsResult(code, permissions, results);
        if (code == CAMERA_PERMISSION_REQUEST || code == DOWNLOAD_CAMERA_PERMISSION_REQUEST) {
            boolean download = code == DOWNLOAD_CAMERA_PERMISSION_REQUEST;
            if (Settings.granted(this, Manifest.permission.CAMERA)) {
                openScanner(download);
            } else {
                showScannerFeedback(download, "请在系统设置中允许使用摄像头。");
            }
        } else if (code == MEDIA_PERMISSION_REQUEST) {
            Settings.Configuration requested = awaitingPermission;
            awaitingPermission = null;
            if (!Settings.hasMediaAccess(this)) {
                showFeedback("自动发现截图和录屏需要访问所有照片和视频。可以用「选择图片上传」发送选中的照片。");
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
            detail = settings.configuration().origin().isEmpty() ? "等待配对"
                    : settings.firstEnabledAt() < 0 ? "已保存配对，自动上传待开启" : "自动上传已暂停";
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
