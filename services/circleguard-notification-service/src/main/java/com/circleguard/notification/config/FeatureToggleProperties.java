package com.circleguard.notification.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

import java.util.HashMap;
import java.util.Map;

/**
 * Feature toggles read from configuration (US-41).
 *
 * <p>Binds {@code circleguard.features.<flag>=true|false}. Each value can be overridden per
 * environment with an environment variable, without changing code or rebuilding the image.
 */
@ConfigurationProperties(prefix = "circleguard")
public class FeatureToggleProperties {

    private Map<String, Boolean> features = new HashMap<>();

    public Map<String, Boolean> getFeatures() {
        return features;
    }

    public void setFeatures(Map<String, Boolean> features) {
        this.features = features;
    }
}
