package com.outbreak.game;

import android.os.Bundle;

import com.getcapacitor.BridgeActivity;

public class MainActivity extends BridgeActivity {
    @Override
    public void onCreate(Bundle savedInstanceState) {
        registerPlugin(PatrolPlugin.class);
        super.onCreate(savedInstanceState);
    }
}
