# NewPipeExtractor arrastra Rhino (org.mozilla.javascript), que referencia
# java.beans / javax.script. Esas clases no están en el Android SDK y R8
# corta el release. No hace falta apagar minify.
-keep class org.schabi.newpipe.extractor.** { *; }
-keep class org.mozilla.javascript.** { *; }
-dontwarn org.schabi.newpipe.**
-dontwarn org.mozilla.javascript.**
-dontwarn java.beans.**
-dontwarn javax.script.**
-dontwarn java.applet.**
