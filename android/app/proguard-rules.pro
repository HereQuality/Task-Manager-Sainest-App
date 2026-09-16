# Required now that release builds have isMinifyEnabled/isShrinkResources
# turned on (see app/build.gradle.kts). Without these, R8 code shrinking
# previously caused flutter_local_notifications' own documented crash on
# this app ("TypeToken must be created with a type argument ... When using
# code shrinkers (ProGuard, R8, ...) make sure that generic signatures are
# preserved") -- it stores its scheduled-notification list as JSON via
# Gson, and shrinking stripped the generic signature Gson's TypeToken
# needs at runtime to deserialize it back, crashing every zonedSchedule
# call (the Notifications screen, and the very first launch's due-soon
# reminder scheduling right after the permission prompt).
-keep class com.dexterous.** { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep class com.google.gson.reflect.TypeToken { *; }
-keepattributes Signature
-keepattributes *Annotation*
