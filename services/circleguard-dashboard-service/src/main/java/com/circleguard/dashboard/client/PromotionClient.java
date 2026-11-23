package com.circleguard.dashboard.client;

import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.github.resilience4j.retry.Retry;
import io.github.resilience4j.retry.RetryRegistry;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.RestTemplate;

import java.time.Duration;
import java.util.*;
import java.util.function.Function;
import java.util.function.Supplier;

/**
 * Cliente de promotion-service para las estadísticas del dashboard.
 * US-23 (SCRUM-92): timeouts, Retry con backoff exponencial y Circuit Breaker de
 * Resilience4j. Si promotion-service no responde, o el breaker está abierto, se
 * devuelve la respuesta de respaldo (fallback) en vez de propagar el error.
 */
@Component
@Slf4j
public class PromotionClient {

    static final String RESILIENCE_INSTANCE = "promotionService";

    private final RestTemplate restTemplate;
    private final String promotionServiceUrl;
    private final Retry retry;
    private final CircuitBreaker circuitBreaker;

    @Autowired
    public PromotionClient(@Value("${circleguard.promotion-service.url:http://localhost:8088}") String promotionServiceUrl,
                           @Value("${circleguard.promotion-service.connect-timeout:1s}") Duration connectTimeout,
                           @Value("${circleguard.promotion-service.read-timeout:2s}") Duration readTimeout,
                           RetryRegistry retryRegistry,
                           CircuitBreakerRegistry circuitBreakerRegistry) {
        SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
        requestFactory.setConnectTimeout((int) connectTimeout.toMillis());
        requestFactory.setReadTimeout((int) readTimeout.toMillis());
        this.restTemplate = new RestTemplate(requestFactory);
        this.promotionServiceUrl = stripTrailingSlashes(promotionServiceUrl);
        this.retry = retryRegistry.retry(RESILIENCE_INSTANCE);
        this.circuitBreaker = circuitBreakerRegistry.circuitBreaker(RESILIENCE_INSTANCE);
    }

    /** Quita las barras finales de la URL sin usar regex (evita backtracking, Sonar S5852). */
    private static String stripTrailingSlashes(String url) {
        int end = url.length();
        while (end > 0 && url.charAt(end - 1) == '/') {
            end--;
        }
        return url.substring(0, end);
    }

    public Map<String, Object> getHealthStats() {
        return call("/api/v1/health-status/stats",
                e -> Map.of("error", "Service unavailable", "timestamp", new Date()));
    }

    public Map<String, Object> getHealthStatsByDepartment(String department) {
        return call("/api/v1/health-status/stats/department/" + department,
                e -> Map.of("error", "Service unavailable", "department", department, "timestamp", new Date()));
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> call(String path, Function<Exception, Map<String, Object>> fallback) {
        Supplier<Map<String, Object>> request = () -> restTemplate.getForObject(promotionServiceUrl + path, Map.class);
        // Retry por fuera del Circuit Breaker: cada intento cuenta para el breaker y,
        // si el breaker está abierto, se responde con el fallback sin llamar al servicio.
        Supplier<Map<String, Object>> resilient = Retry.decorateSupplier(retry,
                CircuitBreaker.decorateSupplier(circuitBreaker, request));
        try {
            return resilient.get();
        } catch (Exception e) {
            log.warn("promotion-service no disponible ({}), se usa el fallback: {}", path, e.toString());
            return fallback.apply(e);
        }
    }
}
