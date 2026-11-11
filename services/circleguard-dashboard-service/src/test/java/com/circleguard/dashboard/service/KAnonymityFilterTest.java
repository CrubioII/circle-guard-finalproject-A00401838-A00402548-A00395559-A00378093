package com.circleguard.dashboard.service;

import org.junit.jupiter.api.Test;

import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * US-32: reglas de k-anonimato del dashboard (FR-23).
 */
class KAnonymityFilterTest {

    private final KAnonymityFilter filter = new KAnonymityFilter();

    @Test
    void nullStatsReturnEmptyMap() {
        assertTrue(filter.apply(null).isEmpty());
    }

    @Test
    void masksWholeResultWhenPopulationBelowK() {
        Map<String, Object> stats = new LinkedHashMap<>();
        stats.put("department", "Engineering");
        stats.put("timestamp", "2026-11-09T00:00:00Z");
        stats.put("totalUsers", 3);
        stats.put("suspectCount", 2);

        Map<String, Object> result = filter.apply(stats);

        assertEquals("<5", result.get("totalUsers"));
        assertEquals("Insufficient data for privacy", result.get("note"));
        assertEquals("Engineering", result.get("department"));
        assertEquals("2026-11-09T00:00:00Z", result.get("timestamp"));
        assertFalse(result.containsKey("suspectCount"), "no debe filtrar conteos individuales");
    }

    @Test
    void maskedResultOmitsOptionalFieldsWhenAbsent() {
        Map<String, Object> result = filter.apply(Map.of("totalUsers", 2L));

        assertEquals(2, result.size());
        assertEquals("<5", result.get("totalUsers"));
        assertFalse(result.containsKey("department"));
        assertFalse(result.containsKey("timestamp"));
    }

    @Test
    void masksOnlySmallCountFieldsWhenPopulationIsLargeEnough() {
        Map<String, Object> stats = new HashMap<>();
        stats.put("totalUsers", 100);
        stats.put("suspectCount", 3);
        stats.put("confirmedCount", 0);
        stats.put("activeCount", 90);
        stats.put("probableTotal", 2);
        stats.put("labelCount", "n/a");

        Map<String, Object> result = filter.apply(stats);

        assertEquals("<5", result.get("suspectCount"));
        assertEquals(0, result.get("confirmedCount"), "cero no revela a nadie y se deja igual");
        assertEquals(90, result.get("activeCount"));
        assertEquals(2, result.get("probableTotal"), "solo se enmascaran campos que terminan en Count");
        assertEquals("n/a", result.get("labelCount"));
        assertEquals(100, result.get("totalUsers"));
    }

    @Test
    void customKChangesThreshold() {
        Map<String, Object> stats = Map.of("totalUsers", 50, "suspectCount", 7);

        assertEquals("<10", filter.apply(stats, 10).get("suspectCount"));
        assertEquals(7, filter.apply(stats, 5).get("suspectCount"));
    }

    @Test
    void nonNumericTotalUsersIsIgnored() {
        Map<String, Object> stats = Map.of("totalUsers", "unknown", "suspectCount", 1);

        Map<String, Object> result = filter.apply(stats);

        assertEquals("unknown", result.get("totalUsers"));
        assertEquals("<5", result.get("suspectCount"));
    }

    @Test
    void doesNotMutateInput() {
        Map<String, Object> stats = new HashMap<>(Map.of("totalUsers", 100, "suspectCount", 1));

        filter.apply(stats);

        assertEquals(1, stats.get("suspectCount"));
    }
}
