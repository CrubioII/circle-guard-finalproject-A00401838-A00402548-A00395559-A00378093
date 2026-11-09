package com.circleguard.dashboard.service;

import com.circleguard.dashboard.client.PromotionClient;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.jdbc.core.JdbcTemplate;

import java.util.*;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/**
 * US-32: lógica principal de analítica del dashboard-service.
 */
class AnalyticsServiceTest {

    private JdbcTemplate jdbc;
    private PromotionClient promotionClient;
    private AnalyticsService service;

    @BeforeEach
    void setUp() {
        jdbc = mock(JdbcTemplate.class);
        promotionClient = mock(PromotionClient.class);
        service = new AnalyticsService(jdbc, promotionClient, new KAnonymityFilter());
    }

    @Test
    void campusSummaryAndGlobalStatsComeFromPromotionService() {
        Map<String, Object> stats = Map.of("totalUsers", 1500);
        when(promotionClient.getHealthStats()).thenReturn(stats);

        assertSame(stats, service.getCampusSummary());
        assertSame(stats, service.getGlobalHealthStats());
        verify(promotionClient, times(2)).getHealthStats();
    }

    @Test
    void departmentStatsAreFilteredWithKAnonymity() {
        when(promotionClient.getHealthStatsByDepartment("Law"))
                .thenReturn(Map.of("totalUsers", 40, "suspectCount", 2, "activeCount", 38));

        Map<String, Object> result = service.getDepartmentStats("Law");

        assertEquals("<5", result.get("suspectCount"));
        assertEquals(38, result.get("activeCount"));
    }

    @Test
    void entryTrendsMaskHoursWithFewerThanFiveEntries() {
        UUID locationId = UUID.randomUUID();
        Map<String, Object> busy = new HashMap<>(Map.of("hour", "08:00", "entry_count", 120L));
        Map<String, Object> quiet = new HashMap<>(Map.of("hour", "23:00", "entry_count", 2L));
        when(jdbc.queryForList(contains("FROM entry_logs"), eq(locationId)))
                .thenReturn(new ArrayList<>(List.of(busy, quiet)));

        List<Map<String, Object>> rows = service.getEntryTrends(locationId);

        assertEquals(120L, rows.get(0).get("entry_count"));
        assertFalse(rows.get(0).containsKey("note"));
        assertEquals("<5", rows.get(1).get("entry_count"));
        assertEquals("Insufficient data for privacy", rows.get(1).get("note"));
    }

    @Test
    void timeSeriesUsesHourlyTruncationByDefault() {
        List<Map<String, Object>> expected = List.of(Map.of("bucket", "x", "status", "ACTIVE", "total", 10));
        when(jdbc.queryForList(anyString(), eq(12))).thenReturn(expected);

        assertSame(expected, service.getTimeSeries("hourly", 12));
        verify(jdbc).queryForList(contains("date_trunc('hour'"), eq(12));
    }

    @Test
    void timeSeriesUsesDailyTruncationWhenRequested() {
        when(jdbc.queryForList(anyString(), eq(7))).thenReturn(List.of());

        service.getTimeSeries("daily", 7);

        verify(jdbc).queryForList(contains("date_trunc('day'"), eq(7));
    }

    @Test
    void timeSeriesFallsBackToMockDataWhenQueryFails() {
        when(jdbc.queryForList(anyString(), anyInt())).thenThrow(new RuntimeException("relation does not exist"));

        List<Map<String, Object>> series = service.getTimeSeries("hourly", 3);

        assertEquals(3 * 4, series.size(), "4 estados por cada bucket");
        Set<Object> statuses = new HashSet<>();
        for (Map<String, Object> point : series) {
            statuses.add(point.get("status"));
            assertInstanceOf(Date.class, point.get("bucket"));
            int total = (int) point.get("total");
            if ("ACTIVE".equals(point.get("status"))) {
                assertTrue(total >= 200 && total < 220);
            } else if ("SUSPECT".equals(point.get("status"))) {
                assertTrue(total >= 30 && total < 50);
            } else {
                assertTrue(total >= 10 && total < 30);
            }
        }
        assertEquals(Set.of("ACTIVE", "SUSPECT", "PROBABLE", "CONFIRMED"), statuses);
    }

    @Test
    void mockTimeSeriesIsCappedAt24Buckets() {
        when(jdbc.queryForList(anyString(), anyInt())).thenThrow(new RuntimeException("db down"));

        assertEquals(24 * 4, service.getTimeSeries("daily", 100).size());
    }
}
