package com.circleguard.auth.controller;

import com.circleguard.auth.client.IdentityClient;
import com.circleguard.auth.model.LocalUser;
import com.circleguard.auth.repository.LocalUserRepository;
import com.circleguard.auth.service.JwtTokenService;
import com.circleguard.auth.service.QrTokenService;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.http.ResponseEntity;
import org.springframework.security.authentication.AuthenticationManager;
import org.springframework.security.authentication.BadCredentialsException;
import org.springframework.security.authentication.UsernamePasswordAuthenticationToken;
import org.springframework.security.core.Authentication;

import java.util.List;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class AuthControllersUnitTest {

    @Mock
    private AuthenticationManager authManager;
    @Mock
    private JwtTokenService jwtService;
    @Mock
    private IdentityClient identityClient;
    @Mock
    private QrTokenService qrTokenService;
    @Mock
    private LocalUserRepository userRepository;

    @Test
    void login_badCredentials_returns401() {
        LoginController controller = new LoginController(authManager, jwtService, identityClient);
        when(authManager.authenticate(any())).thenThrow(new BadCredentialsException("bad"));

        ResponseEntity<Map<String, String>> response = controller.login(Map.of("username", "u", "password", "p"));

        assertThat(response.getStatusCode().value()).isEqualTo(401);
        assertThat(response.getBody()).containsEntry("message", "Invalid username or password");
    }

    @Test
    void login_unexpectedError_returns500() {
        LoginController controller = new LoginController(authManager, jwtService, identityClient);
        when(authManager.authenticate(any())).thenReturn(new UsernamePasswordAuthenticationToken("u", null, List.of()));
        when(identityClient.getAnonymousId("u")).thenThrow(new IllegalStateException("identity down"));

        ResponseEntity<Map<String, String>> response = controller.login(Map.of("username", "u"));

        assertThat(response.getStatusCode().value()).isEqualTo(500);
        assertThat(response.getBody().get("message")).contains("identity down");
    }

    @Test
    void visitorHandoff_withoutAnonymousId_returns400() {
        LoginController controller = new LoginController(authManager, jwtService, identityClient);

        assertThat(controller.generateVisitorHandoff(Map.of()).getStatusCode().value()).isEqualTo(400);
    }

    @Test
    void visitorHandoff_issuesVisitorToken() {
        LoginController controller = new LoginController(authManager, jwtService, identityClient);
        UUID id = UUID.randomUUID();
        when(jwtService.generateToken(eq(id), any(Authentication.class))).thenReturn("visitor-token");

        ResponseEntity<Map<String, String>> response = controller.generateVisitorHandoff(Map.of("anonymousId", id.toString()));

        assertThat(response.getStatusCode().value()).isEqualTo(200);
        assertThat(response.getBody())
                .containsEntry("token", "visitor-token")
                .containsEntry("handoffPayload", "HANDOFF_TOKEN:" + id + ":visitor-token");
    }

    @Test
    void qrGenerate_usesAuthenticatedAnonymousId() {
        QrTokenController controller = new QrTokenController(qrTokenService);
        UUID id = UUID.randomUUID();
        when(qrTokenService.generateQrToken(id)).thenReturn("qr");

        ResponseEntity<Map<String, String>> response =
                controller.generateToken(new UsernamePasswordAuthenticationToken(id.toString(), null, List.of()));

        assertThat(response.getBody()).containsEntry("qrToken", "qr").containsEntry("expiresIn", "60");
    }

    @Test
    void usersByPermission_mapsUsernameAndEmail() {
        UserController controller = new UserController(userRepository);
        when(userRepository.findUsersByPermissionName("alerts:priority")).thenReturn(List.of(
                LocalUser.builder().username("a").email("a@x.edu").build(),
                LocalUser.builder().username("b").build()));

        ResponseEntity<List<Map<String, String>>> response = controller.getUsersByPermission("alerts:priority");

        assertThat(response.getBody()).containsExactly(
                Map.of("username", "a", "email", "a@x.edu"),
                Map.of("username", "b", "email", ""));
    }
}
