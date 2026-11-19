package com.example.add_to_app_host;

import android.app.Activity;
import android.os.Bundle;
import io.flutter.embedding.android.FlutterActivity;

/** The host's own screen, which opens the Flutter one. */
public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        startActivity(FlutterActivity.createDefaultIntent(this));
    }
}
