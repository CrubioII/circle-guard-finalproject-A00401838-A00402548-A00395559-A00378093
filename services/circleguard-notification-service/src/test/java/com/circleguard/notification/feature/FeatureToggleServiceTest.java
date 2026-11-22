package com.circleguard.notification.feature;

import com.circleguard.notification.config.FeatureToggleProperties;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class FeatureToggleServiceTest {

    private FeatureToggleService service;

    @BeforeEach
    void setUp() {
        FeatureToggleProperties properties = new FeatureToggleProperties();
        properties.setFeatures(new HashMap<>(Map.of(
                FeatureFlags.EMAIL_NOTIFICATIONS, true,
                FeatureFlags.SMS_NOTIFICATIONS, false)));
        service = new FeatureToggleService(properties);
    }

    @Test
    void enabledFlagIsOn() {
        assertThat(service.isEnabled(FeatureFlags.EMAIL_NOTIFICATIONS)).isTrue();
    }

    @Test
    void disabledFlagIsOff() {
        assertThat(service.isEnabled(FeatureFlags.SMS_NOTIFICATIONS)).isFalse();
    }

    @Test
    void unknownFlagIsOffByDefault() {
        assertThat(service.isEnabled("does-not-exist")).isFalse();
        assertThat(service.isEnabled("does-not-exist")).isFalse();
    }

    @Test
    void snapshotIsUnmodifiable() {
        Map<String, Boolean> snapshot = service.snapshot();

        assertThat(snapshot).containsEntry(FeatureFlags.EMAIL_NOTIFICATIONS, true)
                .containsEntry(FeatureFlags.SMS_NOTIFICATIONS, false);
        assertThatThrownBy(() -> snapshot.put(FeatureFlags.PUSH_NOTIFICATIONS, true))
                .isInstanceOf(UnsupportedOperationException.class);
    }
}
