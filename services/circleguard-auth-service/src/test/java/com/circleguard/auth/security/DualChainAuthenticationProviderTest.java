package com.circleguard.auth.security;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.security.authentication.TestingAuthenticationToken;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.authentication.dao.DaoAuthenticationProvider;
import org.springframework.security.core.Authentication;
import org.springframework.security.ldap.authentication.LdapAuthenticationProvider;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
class DualChainAuthenticationProviderTest {

    @Mock
    private LdapAuthenticationProvider ldapProvider;
    @Mock
    private DaoAuthenticationProvider localProvider;
    @InjectMocks
    private DualChainAuthenticationProvider provider;

    private final Authentication request = new UsernamePasswordAuthenticationToken("user", "pw");

    @Test
    void authenticate_usesLdapWhenItSucceeds() {
        Authentication ok = new UsernamePasswordAuthenticationToken("user", null, java.util.List.of());
        when(ldapProvider.authenticate(request)).thenReturn(ok);

        assertThat(provider.authenticate(request)).isSameAs(ok);
        verifyNoInteractions(localProvider);
    }

    @Test
    void authenticate_fallsBackToLocalDbWhenLdapFails() {
        Authentication ok = new UsernamePasswordAuthenticationToken("user", null, java.util.List.of());
        when(ldapProvider.authenticate(request)).thenThrow(new BadCredentialsException("ldap"));
        when(localProvider.authenticate(request)).thenReturn(ok);

        assertThat(provider.authenticate(request)).isSameAs(ok);
    }

    @Test
    void authenticate_propagatesFailureWhenBothChainsFail() {
        when(ldapProvider.authenticate(request)).thenThrow(new BadCredentialsException("ldap"));
        when(localProvider.authenticate(request)).thenThrow(new BadCredentialsException("local"));

        assertThatThrownBy(() -> provider.authenticate(request)).hasMessage("local");
    }

    @Test
    void supports_onlyUsernamePasswordTokens() {
        assertThat(provider.supports(UsernamePasswordAuthenticationToken.class)).isTrue();
        assertThat(provider.supports(TestingAuthenticationToken.class)).isFalse();
    }
}
