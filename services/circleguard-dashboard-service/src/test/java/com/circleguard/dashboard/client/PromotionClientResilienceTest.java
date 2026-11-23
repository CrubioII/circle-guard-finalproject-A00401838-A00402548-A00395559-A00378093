package com.circleguard.dashboard.client;

import io.github.resilience4j.circuitbreaker.CircuitBreaker;
import io.github.resilience4j.circuitbreaker.CircuitBreakerConfig;
import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.github.resilience4j.retry.RetryConfig;
import io.github.resilience4j.retry.RetryRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.HttpServerErrorException;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestTemplate;

import java.time.Duration;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.springframework.test.web.client.ExpectedCount.never;
import static org.springframework.test.web.client.ExpectedCount.once;
import static org.springframework.test.web.client.ExpectedCount.times;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withServerError;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withStatus;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

/**
 * US-23 (SCRUM-92): Retry, Circuit Breaker y fallback en dashboard -> promotion,
 * con la misma configuración que application.yml pero sin esperas largas.
 */
class PromotionClientResilienceTest {

    private static final String BASE = "http://promotion.test";
    private static final String STATS = BASE + "/api/v1/health-status/stats";

    private CircuitBreakerRegistry circuitBreakerRegistry;
    private PromotionClient client;
    private MockRestServiceServer server;

    /** Cliente con Retry de 3 intentos sin espera y el breaker indicado. */
    static PromotionClient newClient(String baseUrl, CircuitBreakerRegistry circuitBreakerRegistry) {
        RetryRegistry retryRegistry = RetryRegistry.of(RetryConfig.custom()
                .maxAttempts(3)
                .waitDuration(Duration.ofMillis(1))
                .retryExceptions(ResourceAccessException.class, HttpServerErrorException.class)
                .build());
        return new PromotionClient(baseUrl, Duration.ofSeconds(1), Duration.ofSeconds(2),
                retryRegistry, circuitBreakerRegistry);
    }

    @BeforeEach
    void setUp() {
        circuitBreakerRegistry = CircuitBreakerRegistry.of(CircuitBreakerConfig.custom()
                .slidingWindowSize(4)
                .minimumNumberOfCalls(4)
                .failureRateThreshold(50)
                .waitDurationInOpenState(Duration.ofMinutes(1))
                .recordExceptions(ResourceAccessException.class, HttpServerErrorException.class)
                .build());
        client = newClient(BASE, circuitBreakerRegistry);
        RestTemplate restTemplate = (RestTemplate) ReflectionTestUtils.getField(client, "restTemplate");
        server = MockRestServiceServer.bindTo(restTemplate).build();
    }

    @Test
    void retriesTransientServerErrorAndReturnsRealStats() {
        server.expect(once(), requestTo(STATS)).andRespond(withServerError());
        server.expect(once(), requestTo(STATS)).andRespond(
                withSuccess("{\"totalUsers\":1500}", MediaType.APPLICATION_JSON));

        assertThat(client.getHealthStats()).containsEntry("totalUsers", 1500);
        server.verify();
    }

    @Test
    void doesNotRetryClientErrorsAndFallsBack() {
        server.expect(once(), requestTo(STATS)).andRespond(withStatus(HttpStatus.NOT_FOUND));

        assertThat(client.getHealthStats()).containsEntry("error", "Service unavailable");
        server.verify();
        assertThat(breaker().getMetrics().getNumberOfFailedCalls()).isZero();
    }

    @Test
    void opensCircuitAndAnswersFallbackWithoutCallingPromotion() {
        // 2 consultas fallidas x 3 intentos = 4 fallos en la ventana -> el breaker se abre
        server.expect(times(4), requestTo(STATS)).andRespond(withServerError());
        server.expect(never(), requestTo(STATS));

        assertThat(client.getHealthStats()).containsEntry("error", "Service unavailable");
        assertThat(client.getHealthStats()).containsEntry("error", "Service unavailable");
        assertThat(breaker().getState()).isEqualTo(CircuitBreaker.State.OPEN);

        // Con el breaker abierto responde el fallback de inmediato
        Map<String, Object> stats = client.getHealthStatsByDepartment("Law");
        assertThat(stats).containsEntry("error", "Service unavailable").containsEntry("department", "Law");
        server.verify();
    }

    private CircuitBreaker breaker() {
        return circuitBreakerRegistry.circuitBreaker(PromotionClient.RESILIENCE_INSTANCE);
    }
}
