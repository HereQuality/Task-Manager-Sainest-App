# Not currently used -- this release build type has isMinifyEnabled/
# isShrinkResources explicitly set to false (see app/build.gradle.kts),
# specifically because R8 code shrinking is what caused
# flutter_local_notifications' own documented crash on this app
# ("TypeToken must be created with a type argument ... When using code
# shrinkers (ProGuard, R8, ...) make sure that generic signatures are
# preserved") -- it stores its scheduled-notification list as JSON via
# Gson, and shrinking stripped the generic signature Gson's TypeToken
# needs at runtime to deserialize it back, crashing every zonedSchedule
# call (the Notifications screen, and the very first launch's due-soon
# reminder scheduling right after the permission prompt).
#
# Kept here, referenced but inert, as a documented safety net: if
# shrinking is ever turned back on for a smaller APK, these rules (the
# ones flutter_local_notifications' own README recommends) must ship
# alongside that change, not be rediscovered from scratch.
-keep class com.dexterous.** { *; }
-keep class * extends com.google.gson.reflect.TypeToken
-keep class com.google.gson.reflect.TypeToken { *; }
-keepattributes Signature
-keepattributes *Annotation*
