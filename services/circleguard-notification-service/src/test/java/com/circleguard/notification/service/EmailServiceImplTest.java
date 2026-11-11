package com.circleguard.notification.service;

import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.mail.MailSendException;
import org.springframework.mail.SimpleMailMessage;
import org.springframework.mail.javamail.JavaMailSender;

import java.util.concurrent.CompletableFuture;

import static org.junit.jupiter.api.Assertions.*;
import static org.mockito.ArgumentMatchers.*;
import static org.mockito.Mockito.*;

/**
 * US-32: envío de correo sin contexto Spring (sin @Async ni @Retryable).
 */
class EmailServiceImplTest {

    private final JavaMailSender mailSender = mock(JavaMailSender.class);
    private final AuditLogService auditLogService = mock(AuditLogService.class);
    private final EmailServiceImpl service = new EmailServiceImpl(mailSender, auditLogService);

    @Test
    void sendsEmailAndAuditsSuccess() {
        CompletableFuture<Void> future = service.sendAsync("anon-1", "Your status is SUSPECT");

        assertTrue(future.isDone());
        assertFalse(future.isCompletedExceptionally());
        ArgumentCaptor<SimpleMailMessage> captor = ArgumentCaptor.forClass(SimpleMailMessage.class);
        verify(mailSender).send(captor.capture());
        SimpleMailMessage sent = captor.getValue();
        assertArrayEquals(new String[]{"anon-1@example.com"}, sent.getTo());
        assertEquals("CircleGuard Health Alert", sent.getSubject());
        assertEquals("Your status is SUSPECT", sent.getText());
        verify(auditLogService).logDelivery(eq("anon-1"), eq("EMAIL"), eq("SUCCESS"), anyString());
    }

    @Test
    void auditsRetryAndRethrowsOnFailure() {
        doThrow(new MailSendException("smtp down")).when(mailSender).send(any(SimpleMailMessage.class));

        assertThrows(MailSendException.class, () -> service.sendAsync("anon-1", "msg"));
        verify(auditLogService).logDelivery(eq("anon-1"), eq("EMAIL"), eq("RETRY"), anyString());
    }

    @Test
    void recoverAuditsFailureAndReturnsFailedFuture() {
        RuntimeException error = new RuntimeException("gave up");

        CompletableFuture<Void> future = service.recover(error, "anon-1", "msg");

        assertTrue(future.isCompletedExceptionally());
        verify(auditLogService).logDelivery("anon-1", "EMAIL", "FAILED", null);
    }
}
