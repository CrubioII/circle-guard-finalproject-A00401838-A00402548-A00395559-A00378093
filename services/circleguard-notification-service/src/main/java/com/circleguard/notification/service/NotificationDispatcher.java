package com.circleguard.notification.service;

import com.circleguard.notification.feature.FeatureFlags;
import com.circleguard.notification.feature.FeatureToggleService;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.stereotype.Service;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.concurrent.CompletableFuture;

@Service
@RequiredArgsConstructor
@Slf4j
public class NotificationDispatcher {

    private final EmailService emailService;
    private final SmsService smsService;
    private final PushService pushService;
    private final TemplateService templateService;
    private final FeatureToggleService featureToggleService;

    public void dispatch(String userId, String status) {
        log.info("Dispatching contextual multi-channel notifications for user: {} with status: {}", userId, status);

        List<CompletableFuture<?>> deliveries = new ArrayList<>();

        if (isChannelEnabled(FeatureFlags.EMAIL_NOTIFICATIONS)) {
            String emailContent = templateService.generateEmailContent(status, userId);
            deliveries.add(emailService.sendAsync(userId, emailContent));
        }
        if (isChannelEnabled(FeatureFlags.SMS_NOTIFICATIONS)) {
            String smsContent = templateService.generateSmsContent(status);
            deliveries.add(smsService.sendAsync(userId, smsContent));
        }
        if (isChannelEnabled(FeatureFlags.PUSH_NOTIFICATIONS)) {
            String pushContent = templateService.generatePushContent(status);
            Map<String, String> pushMetadata = templateService.generatePushMetadata(status);
            deliveries.add(pushService.sendAsync(userId, pushContent, pushMetadata));
        }

        if (deliveries.isEmpty()) {
            log.info("All notification channels are disabled by feature toggles; nothing sent to user: {}", userId);
            return;
        }

        CompletableFuture.allOf(deliveries.toArray(new CompletableFuture<?>[0])).handle((result, ex) -> {
            if (ex != null) {
                log.error("Error during multi-channel dispatch for user {}: {}", userId, ex.getMessage());
            } else {
                log.info("Multi-channel dispatch completed successfully for user: {}", userId);
            }
            return result;
        });
    }

    private boolean isChannelEnabled(String flag) {
        boolean enabled = featureToggleService.isEnabled(flag);
        if (!enabled) {
            log.info("Channel {} disabled by feature toggle, skipping", flag);
        }
        return enabled;
    }
}
