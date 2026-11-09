package com.circleguard.identity.service;

import com.circleguard.identity.model.IdentityMapping;
import com.circleguard.identity.repository.IdentityMappingRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.web.server.ResponseStatusException;

import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class IdentityVaultServiceTest {

    @Mock
    private IdentityMappingRepository repository;

    @InjectMocks
    private IdentityVaultService service;

    @BeforeEach
    void setUp() {
        ReflectionTestUtils.setField(service, "hashSalt", "unit-salt");
    }

    @Test
    void getOrCreateAnonymousId_returnsExistingMapping() {
        UUID existing = UUID.randomUUID();
        when(repository.findByIdentityHash(anyString()))
                .thenReturn(Optional.of(IdentityMapping.builder().anonymousId(existing).build()));

        assertThat(service.getOrCreateAnonymousId("jdoe@uni.edu")).isEqualTo(existing);
        verify(repository, never()).save(any());
    }

    @Test
    void getOrCreateAnonymousId_createsMappingWithDeterministicHashAndSalt() {
        UUID created = UUID.randomUUID();
        when(repository.findByIdentityHash(anyString())).thenReturn(Optional.empty());
        when(repository.save(any(IdentityMapping.class))).thenAnswer(inv -> {
            IdentityMapping m = inv.getArgument(0);
            m.setAnonymousId(created);
            return m;
        });

        assertThat(service.getOrCreateAnonymousId("jdoe@uni.edu")).isEqualTo(created);

        ArgumentCaptor<IdentityMapping> captor = ArgumentCaptor.forClass(IdentityMapping.class);
        verify(repository).save(captor.capture());
        IdentityMapping saved = captor.getValue();
        assertThat(saved.getRealIdentity()).isEqualTo("jdoe@uni.edu");
        assertThat(saved.getIdentityHash()).hasSize(64).doesNotContain("jdoe");
        assertThat(saved.getSalt()).isNotBlank();

        // El hash es determinista: la misma identidad produce la misma búsqueda.
        ArgumentCaptor<String> hashes = ArgumentCaptor.forClass(String.class);
        service.getOrCreateAnonymousId("jdoe@uni.edu");
        verify(repository, times(2)).findByIdentityHash(hashes.capture());
        assertThat(hashes.getAllValues().get(0)).isEqualTo(hashes.getAllValues().get(1));
    }

    @Test
    void resolveRealIdentity_returnsStoredIdentity() {
        UUID id = UUID.randomUUID();
        when(repository.findById(id)).thenReturn(Optional.of(IdentityMapping.builder().realIdentity("jdoe").build()));

        assertThat(service.resolveRealIdentity(id)).isEqualTo("jdoe");
    }

    @Test
    void resolveRealIdentity_unknownId_throws404() {
        UUID id = UUID.randomUUID();
        when(repository.findById(id)).thenReturn(Optional.empty());

        assertThatThrownBy(() -> service.resolveRealIdentity(id))
                .isInstanceOf(ResponseStatusException.class)
                .hasMessageContaining("Identity not found");
    }
}
