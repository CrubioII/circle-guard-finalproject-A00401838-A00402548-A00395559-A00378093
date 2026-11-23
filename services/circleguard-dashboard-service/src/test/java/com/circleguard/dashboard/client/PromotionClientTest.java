package com.circleguard.dashboard.client;

import io.github.resilience4j.circuitbreaker.CircuitBreakerRegistry;
import io.github.resilience4j.retry.RetryConfig;
import io.github.resilience4j.retry.RetryRegistry;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestTemplate;

import java.time.Duration;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;
import static org.springframework.test.web.client.ExpectedCount.times;
import static org.springframework.test.web.client.match.MockRestRequestMatchers.requestTo;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withServerError;
import static org.springframework.test.web.client.response.MockRestResponseCreators.withSuccess;

/**
 * US-32: cliente HTTP hacia promotion-service, incluido el fallback cuando no responde.
 */
class PromotionClientTest {

    private static final String BASE = "http://promotion.test";

    private PromotionClient client;
    private MockRestServiceServer server;

    @BeforeEach
    void setUp() {
        // US-23: Retry de 3 intentos sin espera para que las pruebas sean rápidas
        RetryRegistry retryRegistry = RetryRegistry.of(RetryConfig.custom()
                .maxAttempts(3).waitDuration(Duration.ofMillis(1)).build());
        client = new PromotionClient(BASE, Duration.ofSeconds(1), Duration.ofSeconds(2),
                retryRegistry, CircuitBreakerRegistry.ofDefaults());
        RestTemplate restTemplate = (RestTemplate) ReflectionTestUtils.getField(client, "restTemplate");
        server = MockRestServiceServer.bindTo(restTemplate).build();
    }

    @Test
    void getHealthStatsReturnsPromotionResponse() {
        server.expect(requestTo(BASE + "/api/v1/health-status/stats"))
                .andRespond(withSuccess("{\"totalUsers\":1500,\"suspectCount\":12}", MediaType.APPLICATION_JSON));

        Map<String, Object> stats = client.getHealthStats();

        assertEquals(1500, stats.get("totalUsers"));
        assertEquals(12, stats.get("suspectCount"));
        server.verify();
    }

    @Test
    void getHealthStatsFallsBackWhenServiceFails() {
        // US-23: un 5xx se reintenta 3 veces antes de usar el fallback
        server.expect(times(3), requestTo(BASE + "/api/v1/health-status/stats")).andRespond(withServerError());

        Map<String, Object> stats = client.getHealthStats();

        assertEquals("Service unavailable", stats.get("error"));
        assertNotNull(stats.get("timestamp"));
    }

    @Test
    void getHealthStatsByDepartmentReturnsPromotionResponse() {
        server.expect(requestTo(BASE + "/api/v1/health-status/stats/department/Law"))
                .andRespond(withSuccess("{\"department\":\"Law\",\"totalUsers\":40}", MediaType.APPLICATION_JSON));

        Map<String, Object> stats = client.getHealthStatsByDepartment("Law");

        assertEquals("Law", stats.get("department"));
        assertEquals(40, stats.get("totalUsers"));
        server.verify();
    }

    @Test
    void getHealthStatsByDepartmentFallsBackWhenServiceFails() {
        server.expect(times(3), requestTo(BASE + "/api/v1/health-status/stats/department/Law")).andRespond(withServerError());

        Map<String, Object> stats = client.getHealthStatsByDepartment("Law");

        assertEquals("Service unavailable", stats.get("error"));
        assertEquals("Law", stats.get("department"));
        assertNotNull(stats.get("timestamp"));
    }
}
