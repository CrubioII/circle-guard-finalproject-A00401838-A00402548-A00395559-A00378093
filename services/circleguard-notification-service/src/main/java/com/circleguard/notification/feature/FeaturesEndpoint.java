package com.circleguard.notification.feature;

import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.ReadOperation;
import org.springframework.stereotype.Component;

import java.util.Map;

/** Exposes the current feature toggles at {@code GET /actuator/features} (US-41). */
@Component
@Endpoint(id = "features")
public class FeaturesEndpoint {

    private final FeatureToggleService featureToggleService;

    public FeaturesEndpoint(FeatureToggleService featureToggleService) {
        this.featureToggleService = featureToggleService;
    }

    @ReadOperation
    public Map<String, Boolean> features() {
        return featureToggleService.snapshot();
    }
}
