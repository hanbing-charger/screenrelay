package com.screenrelay.mobile;

import android.Manifest;
import android.app.Activity;
import android.content.ActivityNotFoundException;
import android.content.ClipData;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Insets;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.graphics.drawable.StateListDrawable;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.text.InputType;
import android.text.TextUtils;
import android.text.format.Formatter;
import android.util.StateSet;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
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
import java.util.Set;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private static final int CAMERA_PERMISSION_REQUEST = 3;
    private static final int QR_SCAN_REQUEST = 4;
    private static final int DOWNLOAD_CAMERA_PERMISSION_REQUEST = 5;
    private static final int DOWNLOAD_SCAN_REQUEST = 6;
    private static final int CHOOSE_IMAGES_REQUEST = 7;
    private static final String MANUAL_PAIRING_VISIBLE = "manualPairingVisible";
    private static final int BLUE = Color.rgb(37, 88, 221);
    private static final int INK = Color.rgb(23, 36, 62);
    private static final int SECONDARY = Color.rgb(72, 88, 113);
    private static final int BORDER = Color.rgb(218, 226, 240);
    private static final int BACKGROUND = Color.rgb(243, 246, 252);
    private static final int BLUE_SURFACE = Color.rgb(238, 244, 255);
    private static final int BLUE_BORDER = Color.rgb(205, 218, 247);

    private final Handler main = new Handler(Looper.getMainLooper());
    private final ExecutorService connectionTest = Executors.newSingleThreadExecutor();
    private final Runnable refreshDownload = this::refreshDownloadStatus;
    private final Runnable refreshImages = this::refreshImageUploads;
    private Settings settings;
    private IncomingDownloads downloads;
    private ManualImageUploads imageUploads;
    private boolean manualPairingVisible;
    private EditText address;
    private EditText secret;
    private TextView pairingStatus;
    private TextView pairingEndpoint;
    private TextView feedback;
    private Button savePairing;
    private Button scan;
    private Button editPairing;
    private LinearLayout pairingForm;
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
        manualPairingVisible = state != null && state.getBoolean(MANUAL_PAIRING_VISIBLE);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
        setContentView(makeScreen());
        Settings.Configuration saved = settings.configuration();
        address.setText(saved.origin());
        secret.setText(saved.token());
        downloads.restoreOnce();
    }

    @Override
    protected void onSaveInstanceState(Bundle state) {
        super.onSaveInstanceState(state);
        state.putBoolean(MANUAL_PAIRING_VISIBLE, manualPairingVisible);
    }

    @Override
    protected void onResume() {
        super.onResume();
        refreshPairing();
        refreshDownloadStatus();
        refreshImageUploads();
    }

    @Override
    protected void onPause() {
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
        scroll.setBackgroundColor(BACKGROUND);

        LinearLayout content = column();
        content.setGravity(Gravity.CENTER_HORIZONTAL);
        scroll.addView(content);
        LinearLayout page = column();
        page.setFocusableInTouchMode(true);
        content.addView(page, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        content.addOnLayoutChangeListener((view, left, top, right, bottom, oldLeft, oldTop, oldRight, oldBottom) -> {
            int width = Math.min(dp(540), right - left);
            ViewGroup.LayoutParams layout = page.getLayoutParams();
            if (width > 0 && layout.width != width) {
                layout.width = width;
                page.setLayoutParams(layout);
            }
        });

        int margin = dp(22);
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

        TextView title = text("截屏快传", 36, INK, true);
        title.setAccessibilityHeading(true);
        add(page, title, 4);
        add(page, text("在同一局域网内传送图片和文件", 15, SECONDARY, false), 6);
        add(page, makeImageUploadCard(), 24);
        add(page, makeDownloadCard(), 14);
        add(page, makePairingCard(), 18);

        Button diagnostics = button("诊断日志", false);
        diagnostics.setOnClickListener(view -> startActivity(new Intent(this, DiagnosticActivity.class)));
        add(page, diagnostics, 14);
        return scroll;
    }

    private View makePairingCard() {
        LinearLayout pairing = card();
        TextView title = text("电脑配对", 19, INK, true);
        title.setAccessibilityHeading(true);
        add(pairing, title, 0);

        pairingStatus = text("", 13, BLUE, true);
        pairingStatus.setPadding(dp(10), dp(5), dp(10), dp(5));
        pairingStatus.setBackground(rounded(BLUE_SURFACE, BLUE_SURFACE, 12));
        pairingStatus.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        LinearLayout.LayoutParams label = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        label.topMargin = dp(8);
        pairing.addView(pairingStatus, label);
        pairingEndpoint = text("", 14, SECONDARY, false);
        add(pairing, pairingEndpoint, 8);

        scan = button("扫码配对", false);
        scan.setOnClickListener(view -> onScan(false));
        add(pairing, scan, 14);
        editPairing = button("手动配对", false);
        editPairing.setOnClickListener(view -> {
            manualPairingVisible = !manualPairingVisible;
            refreshPairing();
        });
        add(pairing, editPairing, 8);
        feedback = text("", 14, SECONDARY, false);
        feedback.setAccessibilityLiveRegion(View.ACCESSIBILITY_LIVE_REGION_POLITE);
        feedback.setVisibility(View.GONE);
        add(pairing, feedback, 8);

        pairingForm = column();
        add(pairing, pairingForm, 6);
        address = field("http://192.168.1.10:8765",
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
        labelField(pairingForm, "电脑地址", address);
        secret = field("电脑上的配对密钥",
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        labelField(pairingForm, "配对密钥", secret);

        savePairing = button("保存配对", true);
        savePairing.setOnClickListener(view -> {
            Settings.Configuration configuration = readConfiguration();
            if (configuration != null) {
                savePairing(configuration, "已保存配对。");
            }
        });
        add(pairingForm, savePairing, 18);
        test = button("测试连接", false);
        test.setOnClickListener(view -> onTest());
        add(pairingForm, test, 8);
        return pairing;
    }

    private void refreshPairing() {
        Settings.Configuration saved = settings.configuration();
        boolean paired = !saved.origin().isEmpty() && !saved.token().isEmpty();
        pairingStatus.setText(paired ? "已保存配对" : "未配对");
        pairingEndpoint.setText(paired ? saved.origin() : "用电脑接收端显示的二维码或配对密钥进行配对。");
        pairingForm.setVisibility(manualPairingVisible ? View.VISIBLE : View.GONE);
        editPairing.setText(manualPairingVisible ? "收起配对设置" : paired ? "编辑配对" : "手动配对");
    }

    private View makeImageUploadCard() {
        LinearLayout images = card();
        chooseImages = button("选择图片上传", true);
        chooseImages.setOnClickListener(view -> openImagePicker());
        add(images, chooseImages, 0);
        add(images, text("支持多选，按原文件发送", 14, SECONDARY, false), 9);
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
        imageFeedback = "请先在下方扫码配对，或填入电脑地址和密钥后点「保存配对」。";
        refreshImageUploads();
        return null;
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
        scanDownload = button("扫码接收文件", false);
        scanDownload.setOnClickListener(view -> onScan(true));
        add(download, scanDownload, 0);
        add(download, text("文件保存到手机的「下载」目录", 14, SECONDARY, false), 9);
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
        for (View control : new View[]{scan, savePairing, editPairing, test, address, secret}) {
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
        manualPairingVisible = false;
        savePairing(configuration, "已配对电脑。");
    }

    private void savePairing(Settings.Configuration configuration, String message) {
        if (!configuration.equals(settings.configuration())) {
            settings.saveConfiguration(configuration);
        }
        imageFeedback = "";
        showFeedback(message);
        refreshImageUploads();
        refreshPairing();
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
        }
    }

    private LinearLayout column() {
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL);
        return layout;
    }

    private LinearLayout card() {
        LinearLayout card = column();
        card.setBackground(rounded(Color.WHITE, BORDER, 20));
        int padding = dp(16);
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
        StateListDrawable background = new StateListDrawable();
        background.addState(new int[]{android.R.attr.state_focused}, rounded(Color.WHITE, BLUE, 10));
        background.addState(StateSet.WILD_CARD, rounded(Color.WHITE, BORDER, 10));
        input.setBackground(background);
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
        button.setTextSize(primary ? 17 : 15);
        button.setTypeface(button.getTypeface(), Typeface.BOLD);
        int[] disabled = {-android.R.attr.state_enabled};
        button.setTextColor(new ColorStateList(new int[][]{disabled, StateSet.WILD_CARD},
                new int[]{SECONDARY, primary ? Color.WHITE : BLUE}));
        StateListDrawable background = new StateListDrawable();
        int disabledFill = Color.rgb(231, 237, 247);
        background.addState(disabled, rounded(disabledFill, BORDER, 13));
        background.addState(StateSet.WILD_CARD, rounded(primary ? BLUE : BLUE_SURFACE,
                primary ? BLUE : BLUE_BORDER, 13));
        ColorStateList ripple = ColorStateList.valueOf(primary ? 0x38FFFFFF : 0x262558DD);
        button.setBackground(new RippleDrawable(ripple, background, null));
        button.setPadding(dp(16), dp(11), dp(16), dp(11));
        button.setMinimumHeight(dp(52));
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
