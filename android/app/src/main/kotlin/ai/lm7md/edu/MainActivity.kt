package ai.lm7md.edu

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        if (!flutterEngine.plugins.has(EduNativeRuntimePlugin::class.java)) {
            flutterEngine.plugins.add(EduNativeRuntimePlugin())
        }
    }
}
