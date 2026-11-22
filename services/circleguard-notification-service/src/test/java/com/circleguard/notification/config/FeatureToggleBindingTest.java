package com.circleguard.notification.config;

import com.circleguard.notification.feature.FeatureFlags;
import org.junit.jupiter.api.Test;
import org.springframework.boot.context.properties.bind.Binder;
import org.springframework.boot.context.properties.source.MapConfigurationPropertySource;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;

class FeatureToggleBindingTest {

    @Test
    void bindsFlagsFromConfiguration() {
        MapConfigurationPropertySource source = new MapConfigurationPropertySource(Map.of(
                "circleguard.features.sms-notifications", "false",
                "circleguard.features.email-notifications", "true"));

        FeatureToggleProperties properties = new Binder(source)
                .bind("circleguard", FeatureToggleProperties.class)
                .get();

        assertThat(properties.getFeatures())
                .containsEntry(FeatureFlags.SMS_NOTIFICATIONS, false)
                .containsEntry(FeatureFlags.EMAIL_NOTIFICATIONS, true);
    }
}
