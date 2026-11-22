package com.circleguard.notification.feature;

import com.circleguard.notification.config.FeatureToggleProperties;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.util.Collections;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.concurrent.ConcurrentHashMap;

/**
 * Answers whether a feature is enabled (US-41).
 *
 * <p>Fail-safe: a flag that is not configured counts as disabled, so a typo in a flag name
 * never turns a feature on by accident.
 */
@Service
@Slf4j
public class FeatureToggleService {

    private final FeatureToggleProperties properties;
    private final Set<String> warnedUnknownFlags = ConcurrentHashMap.newKeySet();

    public FeatureToggleService(FeatureToggleProperties properties) {
        this.properties = properties;
    }

    public boolean isEnabled(String flag) {
        Boolean value = properties.getFeatures().get(flag);
        if (value == null) {
            if (warnedUnknownFlags.add(flag)) {
                log.warn("Feature toggle '{}' is not configured; treating it as disabled", flag);
            }
            return false;
        }
        return value;
    }

    public Map<String, Boolean> snapshot() {
        return Collections.unmodifiableMap(new TreeMap<>(properties.getFeatures()));
    }
}
