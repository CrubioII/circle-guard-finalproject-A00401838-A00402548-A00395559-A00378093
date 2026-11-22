package com.circleguard.notification.feature;

import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class FeaturesEndpointTest {

    @Test
    void returnsTheCurrentToggles() {
        FeatureToggleService service = mock(FeatureToggleService.class);
        when(service.snapshot()).thenReturn(Map.of(FeatureFlags.SMS_NOTIFICATIONS, false));

        assertThat(new FeaturesEndpoint(service).features())
                .containsExactlyEntriesOf(Map.of(FeatureFlags.SMS_NOTIFICATIONS, false));
    }
}
