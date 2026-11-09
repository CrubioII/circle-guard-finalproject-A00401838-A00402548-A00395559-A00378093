package com.circleguard.promotion.service;

import com.circleguard.promotion.model.graph.CircleNode;
import com.circleguard.promotion.model.graph.UserNode;
import com.circleguard.promotion.repository.graph.CircleNodeRepository;
import com.circleguard.promotion.repository.graph.UserNodeRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

import java.util.List;
import java.util.Optional;
import java.util.Set;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class CircleServiceTest {

    @Mock
    private CircleNodeRepository circleRepository;
    @Mock
    private HealthStatusService healthStatusService;
    @InjectMocks
    private CircleService service;

    private static UserNode user(String id, String status) {
        return UserNode.builder().anonymousId(id).status(status).build();
    }

    @Test
    void toggleValidity_invalidating_triggersRecoveryForMembers() {
        CircleNode circle = CircleNode.builder().id(1L).name("C").members(Set.of(user("u1", "SUSPECT"), user("u2", "ACTIVE"))).build();
        when(circleRepository.findById(1L)).thenReturn(Optional.of(circle));

        service.toggleCircleValidity(1L);

        assertThat(circle.getIsValid()).isFalse();
        verify(circleRepository).save(circle);
        verify(healthStatusService).resolveStatus("u1");
        verify(healthStatusService).resolveStatus("u2");
    }

    @Test
    void toggleValidity_revalidating_doesNotResolveStatuses() {
        CircleNode circle = CircleNode.builder().id(1L).isValid(false).members(Set.of(user("u1", "ACTIVE"))).build();
        when(circleRepository.findById(1L)).thenReturn(Optional.of(circle));

        service.toggleCircleValidity(1L);

        assertThat(circle.getIsValid()).isTrue();
        verifyNoInteractions(healthStatusService);
    }

    @Test
    void forceFence_promotesOnlyActiveMembersToProbable() {
        CircleNode circle = CircleNode.builder().id(2L).name("Lab")
                .members(Set.of(user("active", "ACTIVE"), user("confirmed", "CONFIRMED"))).build();
        when(circleRepository.findById(2L)).thenReturn(Optional.of(circle));

        service.forceFenceCircle(2L);

        assertThat(circle.getForceFence()).isTrue();
        verify(healthStatusService).updateStatus("active", "PROBABLE");
        verify(healthStatusService, never()).updateStatus(eq("confirmed"), anyString());
    }

    @Test
    void unknownCircle_throws() {
        when(circleRepository.findById(9L)).thenReturn(Optional.empty());
        assertThatThrownBy(() -> service.toggleCircleValidity(9L)).hasMessage("Circle not found");
        assertThatThrownBy(() -> service.forceFenceCircle(9L)).hasMessage("Circle not found");
    }

    @Test
    void createCircle_generatesUniqueMeshInviteCode() {
        when(circleRepository.existsByInviteCode(anyString())).thenReturn(true, false);
        when(circleRepository.save(any(CircleNode.class))).thenAnswer(i -> i.getArgument(0));

        CircleNode created = service.createCircle("Study group", "loc-1");

        assertThat(created.getInviteCode()).matches("MESH-[A-Z2-9]{4}");
        assertThat(created.getIsActive()).isTrue();
        assertThat(created.getLocationId()).isEqualTo("loc-1");
        verify(circleRepository, times(2)).existsByInviteCode(anyString());
    }

    @Test
    void joinAndAddMember_delegateAndFailWhenEmpty() {
        CircleNode circle = CircleNode.builder().id(3L).build();
        when(circleRepository.joinCircle("u1", "MESH-AAAA")).thenReturn(Optional.of(circle));
        when(circleRepository.joinCircle("u1", "BAD")).thenReturn(Optional.empty());
        when(circleRepository.addUserToCircle("u2", 3L)).thenReturn(Optional.of(circle));
        when(circleRepository.addUserToCircle("u2", 4L)).thenReturn(Optional.empty());

        assertThat(service.joinCircle("u1", "MESH-AAAA")).isSameAs(circle);
        assertThatThrownBy(() -> service.joinCircle("u1", "BAD")).hasMessageContaining("Invalid invite code");
        assertThat(service.addMember(3L, "u2")).isSameAs(circle);
        assertThatThrownBy(() -> service.addMember(4L, "u2")).hasMessage("Failed to add user to circle");
    }

    @Test
    void getUserCircles_delegates() {
        List<CircleNode> circles = List.of(new CircleNode());
        when(circleRepository.findCirclesByUser("u1")).thenReturn(circles);
        assertThat(service.getUserCircles("u1")).isSameAs(circles);
    }

    @Test
    void autoCircle_createsMeshWhenThresholdReached() {
        UserNodeRepository userRepository = mock(UserNodeRepository.class);
        CircleService circleService = mock(CircleService.class);
        AutoCircleService auto = new AutoCircleService(userRepository, circleRepository, circleService);
        when(userRepository.getCumulativeEncounterDuration("a", "b")).thenReturn(3600L);
        when(circleRepository.findCommonCircles("a", "b")).thenReturn(List.of(CircleNode.builder().isAutoGenerated(false).build()));

        auto.evaluateEncounter("a", "b");

        ArgumentCaptor<CircleNode> captor = ArgumentCaptor.forClass(CircleNode.class);
        verify(circleRepository).save(captor.capture());
        CircleNode mesh = captor.getValue();
        assertThat(mesh.getIsAutoGenerated()).isTrue();
        assertThat(mesh.getInviteCode()).startsWith("AUTO-");
        verify(circleService).joinCircle("a", mesh.getInviteCode());
        verify(circleService).joinCircle("b", mesh.getInviteCode());
    }

    @Test
    void autoCircle_skipsWhenAlreadyConnectedBelowThresholdOrInvalidInput() {
        UserNodeRepository userRepository = mock(UserNodeRepository.class);
        CircleService circleService = mock(CircleService.class);
        AutoCircleService auto = new AutoCircleService(userRepository, circleRepository, circleService);
        when(userRepository.getCumulativeEncounterDuration("a", "b")).thenReturn(7200L);
        when(circleRepository.findCommonCircles("a", "b")).thenReturn(List.of(CircleNode.builder().isAutoGenerated(true).build()));
        when(userRepository.getCumulativeEncounterDuration("a", "c")).thenReturn(10L);
        when(userRepository.getCumulativeEncounterDuration("a", "d")).thenReturn(null);

        auto.evaluateEncounter("a", "b");
        auto.evaluateEncounter("a", "c");
        auto.evaluateEncounter("a", "d");
        auto.evaluateEncounter(null, "b");
        auto.evaluateEncounter("a", null);
        auto.evaluateEncounter("a", "a");

        verify(circleRepository, never()).save(any());
        verifyNoInteractions(circleService);
    }
}
