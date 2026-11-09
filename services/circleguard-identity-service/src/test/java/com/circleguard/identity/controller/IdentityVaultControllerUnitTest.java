package com.circleguard.identity.controller;

import com.circleguard.identity.event.IdentityAccessEvent;
import com.circleguard.identity.service.IdentityVaultService;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.kafka.core.KafkaTemplate;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.context.SecurityContextHolder;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class IdentityVaultControllerUnitTest {

    @Mock
    private IdentityVaultService vaultService;
    @Mock
    private KafkaTemplate<String, Object> kafkaTemplate;
    @InjectMocks
    private IdentityVaultController controller;

    @AfterEach
    void clear() {
        SecurityContextHolder.clearContext();
    }

    @Test
    void mapIdentity_returnsAnonymousId() {
        UUID id = UUID.randomUUID();
        when(vaultService.getOrCreateAnonymousId("jdoe")).thenReturn(id);

        assertThat(controller.mapIdentity(Map.of("realIdentity", "jdoe")).getBody()).containsEntry("anonymousId", id);
    }

    @Test
    void registerVisitor_buildsCompositeVisitorIdentity() {
        UUID id = UUID.randomUUID();
        when(vaultService.getOrCreateAnonymousId("VISITOR|v@x.com|Ana|Tour")).thenReturn(id);

        var response = controller.registerVisitor(Map.of("name", "Ana", "email", "v@x.com", "reason_for_visit", "Tour"));

        assertThat(response.getBody()).containsEntry("anonymousId", id);
    }

    @Test
    void lookupIdentity_emitsAuditEventWithRequestingUser() {
        UUID id = UUID.randomUUID();
        SecurityContextHolder.getContext().setAuthentication(
                new UsernamePasswordAuthenticationToken("health-officer", null, List.of()));
        when(vaultService.resolveRealIdentity(id)).thenReturn("jdoe");

        assertThat(controller.lookupIdentity(id).getBody()).containsEntry("realIdentity", "jdoe");

        ArgumentCaptor<Object> captor = ArgumentCaptor.forClass(Object.class);
        verify(kafkaTemplate).send(eq("audit.identity.accessed"), captor.capture());
        IdentityAccessEvent event = (IdentityAccessEvent) captor.getValue();
        assertThat(event.getEventType()).isEqualTo("audit.identity.accessed");
        assertThat(event.getSource()).isEqualTo("circleguard-identity-service");
        assertThat(event.getPayload().getAnonymousId()).isEqualTo(id);
        assertThat(event.getPayload().getRequestingUser()).isEqualTo("health-officer");
        assertThat(event.getPayload().getAccessStatus()).isEqualTo("SUCCESS");
        assertThat(event.getMetadata().getVersion()).isEqualTo(1);
        assertThat(event.getMetadata().getCorrelationId()).isNotBlank();
    }

    @Test
    void lookupIdentity_unexpectedError_auditsAsErrorAndSystemUser() {
        UUID id = UUID.randomUUID();
        when(vaultService.resolveRealIdentity(id)).thenThrow(new IllegalStateException("db down"));

        assertThatThrownBy(() -> controller.lookupIdentity(id)).isInstanceOf(IllegalStateException.class);

        ArgumentCaptor<Object> captor = ArgumentCaptor.forClass(Object.class);
        verify(kafkaTemplate).send(eq("audit.identity.accessed"), captor.capture());
        IdentityAccessEvent event = (IdentityAccessEvent) captor.getValue();
        assertThat(event.getPayload().getAccessStatus()).isEqualTo("ERROR");
        assertThat(event.getPayload().getRequestingUser()).isEqualTo("system");
    }
}
