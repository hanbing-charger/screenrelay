package com.screenrelay.mobile;

import com.journeyapps.barcodescanner.CaptureActivity;
import com.journeyapps.barcodescanner.DecoratedBarcodeView;

public final class PairingScannerActivity extends CaptureActivity {
    @Override
    protected DecoratedBarcodeView initializeContent() {
        DecoratedBarcodeView scanner = super.initializeContent();
        scanner.getViewFinder().setLaserVisibility(false);
        return scanner;
    }
}
