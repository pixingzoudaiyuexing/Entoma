package com.it_nomads.fluttersecurestorage;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.Context;
import android.content.SharedPreferences;
import android.os.Bundle;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;

/** Device-only fault injection: never opens the application's real vault namespace. */
public final class JournalStorageInstrumentation extends Instrumentation {
    private static final String FIXTURE_PREFS = "EntomaJournalCipherFixture";
    private static final String PREFIX = "entoma_cipher_fixture";

    @Override public void onCreate(Bundle arguments) {
        super.onCreate(arguments);
        start();
    }

    private FlutterSecureStorage storage(boolean reset) throws Exception {
        Map<String, Object> options = new HashMap<>();
        options.put("sharedPreferencesName", FIXTURE_PREFS);
        options.put("preferencesKeyPrefix", PREFIX);
        options.put("resetOnError", Boolean.toString(reset));
        options.put("migrateOnAlgorithmChange", "false");
        options.put("keyCipherAlgorithm", "RSA_ECB_OAEPwithSHA_256andMGF1Padding");
        options.put("storageCipherAlgorithm", "AES_GCM_NoPadding");
        FlutterSecureStorage value = new FlutterSecureStorage(getTargetContext());
        CountDownLatch ready = new CountDownLatch(1);
        AtomicReference<Exception> error = new AtomicReference<>();
        value.initialize(new FlutterSecureStorageConfig(options), new SecurePreferencesCallback<Void>() {
            @Override public void onSuccess(Void ignored) { ready.countDown(); }
            @Override public void onError(Exception e) { error.set(e); ready.countDown(); }
        });
        if (!ready.await(20, TimeUnit.SECONDS)) throw new IllegalStateException("fixture deadline");
        if (error.get() != null) throw error.get();
        return value;
    }

    private void require(boolean condition) {
        if (!condition) throw new AssertionError("fixture assertion failed");
    }

    @Override public void onStart() {
        Bundle result = new Bundle();
        SharedPreferences fixture = getTargetContext().getSharedPreferences(FIXTURE_PREFS, Context.MODE_PRIVATE);
        String journalKey = PREFIX + "_journal";
        String sentinelKey = PREFIX + "_sentinel";
        int resultCode = Activity.RESULT_CANCELED;
        try {
            // Only this named fixture file is reset; no global deleteAll or key deletion.
            require(fixture.edit().clear().commit());
            FlutterSecureStorage protectedStore = storage(false);
            protectedStore.write(journalKey, "fixture-unknown-operation");
            protectedStore.write(sentinelKey, "fixture-unrelated-value");
            require("fixture-unknown-operation".equals(protectedStore.read(journalKey)));
            require(fixture.edit().putString(journalKey, "AA==").commit());
            boolean threw = false;
            try { protectedStore.read(journalKey); } catch (Exception expected) { threw = true; }
            require(threw && fixture.contains(journalKey));
            require("fixture-unrelated-value".equals(protectedStore.read(sentinelKey)));
            result.putBoolean("resetDisabledReturnsErrorAndPreservesCiphertext", true);
            result.putBoolean("unrelatedFixtureItemPreserved", true);

            // Reproduce the old option on the SAME isolated corrupt fixture.
            FlutterSecureStorage oldBehavior = storage(true);
            require(oldBehavior.read(journalKey) == null);
            require(!fixture.contains(journalKey));
            require("fixture-unrelated-value".equals(oldBehavior.read(sentinelKey)));
            result.putBoolean("oldResetOptionSilentlyReturnsMissing", true);
            result.putString("scope", "isolated native cipher fixture; no account or financial request");
            resultCode = Activity.RESULT_OK;
        } catch (Throwable error) {
            // Never emit exception messages/stacks or native storage contents.
            result.putString("failureClass", error.getClass().getSimpleName());
            Throwable cause = error.getCause();
            result.putString("causeClass", cause == null ? "none" : cause.getClass().getSimpleName());
            if (cause instanceof ClassNotFoundException) {
                String message = cause.getMessage();
                java.util.regex.Matcher missing = java.util.regex.Pattern
                        .compile("class \\\"([A-Za-z0-9_.$]+)\\\"")
                        .matcher(message == null ? "" : message);
                if (missing.find()) result.putString("missingClass", missing.group(1));
            }
            StackTraceElement[] frames = error.getStackTrace();
            if (frames.length > 0) {
                result.putString("failureMethod", frames[0].getClassName() + "." + frames[0].getMethodName());
            }
        } finally {
            fixture.edit().clear().commit();
        }
        finish(resultCode, result);
    }
}
