package com.circleguard.notification.config;

import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.annotation.Configuration;

@Configuration
@EnableConfigurationProperties(FeatureToggleProperties.class)
public class FeatureToggleConfig {
}
