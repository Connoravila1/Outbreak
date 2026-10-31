package com.outbreak.game;

import android.os.Bundle;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(PatrolPlugin.class);
        super.onCreate(savedInstanceState);
        followSystemFontScale();
    }

    @Override
    public void onResume() {
        super.onResume();
        followSystemFontScale();
    }

    /** Make the web content follow the system font size (Settings > Display > Font size), capped at 200%. */
    private void followSystemFontScale() {
        if (getBridge() == null || getBridge().getWebView() == null) return;
        float scale = getResources().getConfiguration().fontScale;
        int zoom = Math.max(100, Math.min(200, Math.round(scale * 100)));
        getBridge().getWebView().getSettings().setTextZoom(zoom);
    }
}
