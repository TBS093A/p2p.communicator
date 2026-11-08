# Classes that native (Rust) code reaches by name over JNI. R8 cannot see
# those uses, so without these rules it strips or renames the classes and
# release builds fail at startup with
#   VeilidAPIException: Internal (Generic: Could not initialize the protected store.)
# while debug builds (no R8) work. Same rules as VeilidChat's.

# keyring-manager (veilid-core's protected store) drives these over JNI.
-keep class androidx.security.crypto.MasterKey { public static <fields>; }
-keep class androidx.security.crypto.MasterKey$Builder { public <init>(...); public *; }
-keep class androidx.security.crypto.EncryptedSharedPreferences { public static ** create(...); }
-keep class androidx.security.crypto.EncryptedSharedPreferences$PrefKeyEncryptionScheme { public static <fields>; }
-keep class androidx.security.crypto.EncryptedSharedPreferences$PrefValueEncryptionScheme { public static <fields>; }

# veilid's native library binds init_android by its JNI symbol name.
-keepclasseswithmembernames class com.veilid.veilid.VeilidPlugin { native <methods>; }
