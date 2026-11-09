package com.circleguard.dashboard.client;

import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.test.web.client.MockRestServiceServer;
import org.springframework.web.client.RestTemplate;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;
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
        client = new PromotionClient();
        ReflectionTestUtils.setField(client, "promotionServiceUrl", BASE);
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
        server.expect(requestTo(BASE + "/api/v1/health-status/stats")).andRespond(withServerError());

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
        server.expect(requestTo(BASE + "/api/v1/health-status/stats/department/Law")).andRespond(withServerError());

        Map<String, Object> stats = client.getHealthStatsByDepartment("Law");

        assertEquals("Service unavailable", stats.get("error"));
        assertEquals("Law", stats.get("department"));
        assertNotNull(stats.get("timestamp"));
    }
}
