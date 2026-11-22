package com.circleguard.notification.service;

import com.circleguard.notification.feature.FeatureFlags;
import com.circleguard.notification.feature.FeatureToggleService;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;

import java.util.concurrent.CompletableFuture;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.*;

@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class NotificationDispatcherTest {

    @Mock
    private EmailService emailService;
    @Mock
    private SmsService smsService;
    @Mock
    private PushService pushService;
    @Mock
    private TemplateService templateService;
    @Mock
    private FeatureToggleService featureToggleService;

    private NotificationDispatcher dispatcher;

    @BeforeEach
    void setUp() {
        dispatcher = new NotificationDispatcher(emailService, smsService, pushService, templateService, featureToggleService);
        when(emailService.sendAsync(any(), any())).thenReturn(CompletableFuture.completedFuture(null));
        when(smsService.sendAsync(any(), any())).thenReturn(CompletableFuture.completedFuture(null));
        when(pushService.sendAsync(any(), any(), any())).thenReturn(CompletableFuture.completedFuture(null));
        when(featureToggleService.isEnabled(anyString())).thenReturn(true);
    }

    @Test
    void shouldDispatchToAllChannelsWhenAllAreEnabled() {
        dispatcher.dispatch("user-123", "Your health status has changed.");

        verify(emailService).sendAsync(eq("user-123"), any());
        verify(smsService).sendAsync(eq("user-123"), any());
        verify(pushService).sendAsync(eq("user-123"), any(), any());
    }

    @Test
    void shouldSkipSmsWhenItsToggleIsOff() {
        when(featureToggleService.isEnabled(FeatureFlags.SMS_NOTIFICATIONS)).thenReturn(false);

        dispatcher.dispatch("user-123", "SUSPECT");

        verify(smsService, never()).sendAsync(any(), any());
        verify(templateService, never()).generateSmsContent(any());
        verify(emailService).sendAsync(eq("user-123"), any());
        verify(pushService).sendAsync(eq("user-123"), any(), any());
    }

    @Test
    void shouldSendNothingWhenAllTogglesAreOff() {
        when(featureToggleService.isEnabled(anyString())).thenReturn(false);

        dispatcher.dispatch("user-123", "SUSPECT");

        verifyNoInteractions(emailService, smsService, pushService, templateService);
    }
}
