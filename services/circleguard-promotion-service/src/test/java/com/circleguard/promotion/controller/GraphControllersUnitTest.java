package com.circleguard.promotion.controller;

import com.circleguard.promotion.model.graph.CircleNode;
import com.circleguard.promotion.model.jpa.SystemSettings;
import com.circleguard.promotion.repository.graph.UserNodeRepository;
import com.circleguard.promotion.repository.jpa.SystemSettingsRepository;
import com.circleguard.promotion.service.AutoCircleService;
import com.circleguard.promotion.service.CircleService;
import com.circleguard.promotion.service.LocationResolutionService;
import com.circleguard.promotion.service.MacSessionRegistry;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Answers;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.data.neo4j.core.Neo4jClient;

import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class GraphControllersUnitTest {

    @Mock
    private CircleService circleService;
    @Mock
    private UserNodeRepository userRepository;
    @Mock
    private AutoCircleService autoCircleService;
    @Mock
    private SystemSettingsRepository settingsRepository;
    @Mock
    private MacSessionRegistry sessionRegistry;
    @Mock
    private LocationResolutionService locationResolutionService;

    @Test
    void circleController_delegatesAllOperations() {
        CircleController controller = new CircleController(circleService);
        CircleNode circle = CircleNode.builder().id(1L).name("C").build();
        CircleController.CircleCreateRequest request = new CircleController.CircleCreateRequest();
        request.setName("C");
        request.setLocationId("loc");
        when(circleService.createCircle("C", "loc")).thenReturn(circle);
        when(circleService.joinCircle("u1", "MESH-AAAA")).thenReturn(circle);
        when(circleService.addMember(1L, "u2")).thenReturn(circle);
        when(circleService.getUserCircles("u1")).thenReturn(List.of(circle));

        assertThat(controller.createCircle(request).getBody()).isSameAs(circle);
        assertThat(controller.joinCircle("MESH-AAAA", "u1").getBody()).isSameAs(circle);
        assertThat(controller.addMember(1L, "u2").getBody()).isSameAs(circle);
        assertThat(controller.getUserCircles("u1").getBody()).containsExactly(circle);
        controller.toggleValidity(1L);
        controller.forceFence(1L);
        verify(circleService).toggleCircleValidity(1L);
        verify(circleService).forceFenceCircle(1L);
    }

    @Test
    void encounterController_recordsEncounterAndEvaluatesAutoCircle() {
        EncounterController controller = new EncounterController(userRepository, autoCircleService);
        EncounterController.EncounterRequest withLocation = new EncounterController.EncounterRequest();
        withLocation.setSourceId("a");
        withLocation.setTargetId("b");
        withLocation.setLocationId("lab");
        EncounterController.EncounterRequest ble = new EncounterController.EncounterRequest();
        ble.setSourceId("a");
        ble.setTargetId("c");

        controller.reportEncounter(withLocation);
        controller.reportEncounter(ble);
        controller.toggleValidity(7L);
        controller.forceFence(8L);

        verify(userRepository).recordEncounter(eq("a"), eq("b"), anyLong(), eq("lab"));
        verify(userRepository).recordEncounter(eq("a"), eq("c"), anyLong(), eq("mobile_ble"));
        verify(autoCircleService).evaluateEncounter("a", "b");
        verify(userRepository).toggleEncounterValidity(7L);
        verify(userRepository).forceEncounterFence(8L);
    }

    @Test
    void meshController_returnsConnectionCounts() {
        MeshController controller = new MeshController(userRepository);
        when(userRepository.getConfirmedConnectionCount("u1")).thenReturn(3L);
        when(userRepository.getUnconfirmedConnectionCount("u1")).thenReturn(5L);

        MeshController.MeshStatsResponse stats = controller.getMeshStats("u1").getBody();

        assertThat(stats.getConfirmedCount()).isEqualTo(3);
        assertThat(stats.getUnconfirmedCount()).isEqualTo(5);
    }

    @Test
    void adminController_initializesDefaultsWhenMissing() {
        AdminController controller = new AdminController(settingsRepository);
        when(settingsRepository.getSettings()).thenReturn(Optional.empty());
        when(settingsRepository.save(any(SystemSettings.class))).thenAnswer(i -> i.getArgument(0));

        SystemSettings settings = controller.getSettings().getBody();

        assertThat(settings.getUnconfirmedFencingEnabled()).isTrue();
        assertThat(settings.getAutoThresholdSeconds()).isEqualTo(3600L);
        assertThat(settings.getMandatoryFenceDays()).isEqualTo(14);
        assertThat(settings.getEncounterWindowDays()).isEqualTo(14);
    }

    @Test
    void adminController_updatesOnlyProvidedFieldsAndToggles() {
        AdminController controller = new AdminController(settingsRepository);
        SystemSettings existing = SystemSettings.builder().id(1L).unconfirmedFencingEnabled(true)
                .autoThresholdSeconds(3600L).mandatoryFenceDays(14).encounterWindowDays(14).build();
        when(settingsRepository.getSettings()).thenReturn(Optional.of(existing));

        SystemSettings partial = SystemSettings.builder().autoThresholdSeconds(1800L).build();
        assertThat(controller.updateSettings(partial).getBody().getAutoThresholdSeconds()).isEqualTo(1800L);
        assertThat(existing.getMandatoryFenceDays()).isEqualTo(14);

        SystemSettings full = SystemSettings.builder().unconfirmedFencingEnabled(false)
                .autoThresholdSeconds(900L).mandatoryFenceDays(10).encounterWindowDays(7).build();
        SystemSettings updated = controller.updateSettings(full).getBody();
        assertThat(updated.getUnconfirmedFencingEnabled()).isFalse();
        assertThat(updated.getMandatoryFenceDays()).isEqualTo(10);
        assertThat(updated.getEncounterWindowDays()).isEqualTo(7);

        assertThat(controller.toggleUnconfirmedFencing(true).getBody().getUnconfirmedFencingEnabled()).isTrue();
        verify(settingsRepository, times(3)).save(existing);
    }

    @Test
    void healthStatsController_aggregatesAnonymizedCounts() {
        Neo4jClient neo4jClient = mock(Neo4jClient.class, Answers.RETURNS_DEEP_STUBS);
        HealthStatsController controller = new HealthStatsController(neo4jClient);
        Map<String, Object> unknown = new HashMap<>();
        unknown.put("status", null);
        unknown.put("total", 2L);
        List<Map<String, Object>> rows = List.of(Map.of("status", "ACTIVE", "total", 10L), unknown);
        when(neo4jClient.query(anyString()).fetch().all()).thenReturn(rows);
        when(neo4jClient.query(anyString()).bind(any()).to("dept").fetch().all()).thenReturn(rows);

        Map<String, Object> global = controller.getStats().getBody();
        assertThat(global).containsEntry("activeCount", 10L).containsEntry("unknownCount", 2L)
                .containsEntry("totalUsers", 12L).containsKey("timestamp");

        Map<String, Object> dept = controller.getStatsByDepartment("ENG").getBody();
        assertThat(dept).containsEntry("department", "ENG").containsEntry("totalUsers", 12L);
    }

    @Test
    void sessionHandshakeController_validatesAndRegisters() {
        SessionHandshakeController controller = new SessionHandshakeController(sessionRegistry);

        assertThat(controller.handshake(Map.of("macAddress", "AA")).getStatusCode().value()).isEqualTo(400);
        assertThat(controller.handshake(Map.of("anonymousId", "u")).getStatusCode().value()).isEqualTo(400);
        assertThat(controller.handshake(Map.of("macAddress", "AA", "anonymousId", "u")).getStatusCode().value()).isEqualTo(200);
        assertThat(controller.closeSession("AA").getStatusCode().value()).isEqualTo(204);

        verify(sessionRegistry).registerSession("AA", "u");
        verify(sessionRegistry).closeSession("AA");
    }

    @Test
    void locationSignalController_validatesAndForwardsSignal() {
        LocationSignalController controller = new LocationSignalController(locationResolutionService);

        assertThat(controller.receiveSignal(Map.of("apMac", "ap", "deviceMac", "dev", "rssi", "-60")).getStatusCode().value())
                .isEqualTo(200);
        assertThat(controller.receiveSignal(Map.of("deviceMac", "dev", "rssi", -60)).getStatusCode().value())
                .isEqualTo(400);

        verify(locationResolutionService).processSignal("ap", "dev", -60.0);
        verifyNoMoreInteractions(locationResolutionService);
    }
}
