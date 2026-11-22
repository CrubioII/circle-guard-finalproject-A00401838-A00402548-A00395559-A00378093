package com.circleguard.notification.feature;

/** Names of the feature toggles of the notification service (US-41). */
public final class FeatureFlags {

    public static final String EMAIL_NOTIFICATIONS = "email-notifications";
    public static final String SMS_NOTIFICATIONS = "sms-notifications";
    public static final String PUSH_NOTIFICATIONS = "push-notifications";

    private FeatureFlags() {
    }
}
