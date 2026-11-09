package com.circleguard.dashboard.controller;

import com.circleguard.dashboard.service.AnalyticsService;
import org.junit.jupiter.api.Test;
import org.mockito.Mockito;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.test.web.servlet.MockMvc;

import java.util.List;
import java.util.Map;

import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.*;

/**
 * US-32: endpoints de resumen, departamento y series de tiempo.
 */
@WebMvcTest(AnalyticsController.class)
class AnalyticsControllerEndpointsTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private AnalyticsService analyticsService;

    @Test
    void summaryReturnsCampusSummary() throws Exception {
        Mockito.when(analyticsService.getCampusSummary()).thenReturn(Map.of("totalUsers", 1500));

        mockMvc.perform(get("/api/v1/analytics/summary"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.totalUsers").value(1500));
    }

    @Test
    void departmentReturnsFilteredStats() throws Exception {
        Mockito.when(analyticsService.getDepartmentStats("Law")).thenReturn(Map.of("suspectCount", "<5"));

        mockMvc.perform(get("/api/v1/analytics/department/Law"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.suspectCount").value("<5"));
    }

    @Test
    void timeSeriesUsesDefaults() throws Exception {
        Mockito.when(analyticsService.getTimeSeries("hourly", 24))
                .thenReturn(List.of(Map.of("status", "ACTIVE", "total", 200)));

        mockMvc.perform(get("/api/v1/analytics/time-series"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$[0].status").value("ACTIVE"));
        Mockito.verify(analyticsService).getTimeSeries("hourly", 24);
    }

    @Test
    void timeSeriesAcceptsPeriodAndLimit() throws Exception {
        Mockito.when(analyticsService.getTimeSeries("daily", 7)).thenReturn(List.of());

        mockMvc.perform(get("/api/v1/analytics/time-series").param("period", "daily").param("limit", "7"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$").isEmpty());
        Mockito.verify(analyticsService).getTimeSeries("daily", 7);
    }
}
