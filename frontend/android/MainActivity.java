package com.outbreak.sonar;
import android.app.Activity; import android.os.Bundle; import android.os.Build;
import android.graphics.Color; import android.view.View; import android.view.Window; import android.view.WindowManager;
import android.webkit.WebView; import android.webkit.WebSettings;
public class MainActivity extends Activity {
  private WebView web;
  @Override protected void onCreate(Bundle b){
    super.onCreate(b);
    Window w=getWindow();
    w.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);
    w.getDecorView().setSystemUiVisibility(View.SYSTEM_UI_FLAG_LAYOUT_STABLE | View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN);
    w.setStatusBarColor(Color.TRANSPARENT);
    w.setNavigationBarColor(Color.TRANSPARENT);
    if (Build.VERSION.SDK_INT >= 28)
      w.getAttributes().layoutInDisplayCutoutMode = WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES;
    web=new WebView(this);
    WebSettings s=web.getSettings();
    s.setJavaScriptEnabled(true); s.setDomStorageEnabled(true);
    s.setAllowFileAccess(true); s.setAllowFileAccessFromFileURLs(true); s.setAllowUniversalAccessFromFileURLs(true);
    web.setBackgroundColor(0xFF000000);
    setContentView(web);
    web.loadUrl("file:///android_asset/app.html");
  }
  @Override public void onBackPressed(){ if(web!=null && web.canGoBack()) web.goBack(); else super.onBackPressed(); }
}
