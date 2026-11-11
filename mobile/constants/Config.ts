/**
 * Global Configuration for CircleGuard Mobile & Web Client (US-07 / SCRUM-19).
 *
 * Resolution priority (highest to lowest):
 *   1. Runtime browser config injected at container startup (/runtime-config.js -> globalThis.__CIRCLEGUARD_CONFIG__)
 *   2. Build-time / environment variables (process.env.EXPO_PUBLIC_* or process.env.*)
 *   3. Local development defaults (http://localhost:<port>)
 */

export interface CircleGuardRuntimeConfig {
  APP_ENV?: string;
  API_BASE_URL?: string;
  GATEWAY_BASE_URL?: string;
  AUTH_BASE_URL?: string;
  IDENTITY_BASE_URL?: string;
  PROMOTION_BASE_URL?: string;
  FORM_BASE_URL?: string;
  FILE_BASE_URL?: string;
  NOTIFICATION_BASE_URL?: string;
  DASHBOARD_BASE_URL?: string;
}

declare global {
  // eslint-disable-next-line no-var
  var __CIRCLEGUARD_CONFIG__: CircleGuardRuntimeConfig | undefined;
}

const stripTrailingSlash = (url: string): string => url.replace(/\/+$/, '');

export const resolveConfigValue = (
  key: keyof CircleGuardRuntimeConfig,
  envValue: string | undefined,
  fallback: string
): string => {
  const runtimeCfg =
    typeof globalThis !== 'undefined' ? globalThis.__CIRCLEGUARD_CONFIG__ : undefined;
  const candidate = runtimeCfg?.[key] || envValue || fallback;
  return stripTrailingSlash(candidate.trim());
};

export const APP_ENV = resolveConfigValue(
  'APP_ENV',
  process.env.EXPO_PUBLIC_APP_ENV || process.env.APP_ENV,
  'dev'
);

export const AUTH_BASE_URL = resolveConfigValue(
  'AUTH_BASE_URL',
  process.env.EXPO_PUBLIC_AUTH_BASE_URL || process.env.AUTH_BASE_URL,
  'http://localhost:8180'
);

export const DASHBOARD_BASE_URL = resolveConfigValue(
  'DASHBOARD_BASE_URL',
  process.env.EXPO_PUBLIC_DASHBOARD_BASE_URL || process.env.DASHBOARD_BASE_URL,
  'http://localhost:8084'
);

export const FILE_BASE_URL = resolveConfigValue(
  'FILE_BASE_URL',
  process.env.EXPO_PUBLIC_FILE_BASE_URL || process.env.FILE_BASE_URL,
  'http://localhost:8085'
);

export const FORM_BASE_URL = resolveConfigValue(
  'FORM_BASE_URL',
  process.env.EXPO_PUBLIC_FORM_BASE_URL || process.env.FORM_BASE_URL,
  'http://localhost:8086'
);

export const GATEWAY_BASE_URL = resolveConfigValue(
  'GATEWAY_BASE_URL',
  process.env.EXPO_PUBLIC_GATEWAY_BASE_URL ||
    process.env.GATEWAY_BASE_URL ||
    process.env.EXPO_PUBLIC_API_BASE_URL ||
    process.env.API_BASE_URL,
  'http://localhost:8087'
);

export const API_BASE_URL = resolveConfigValue(
  'API_BASE_URL',
  process.env.EXPO_PUBLIC_API_BASE_URL ||
    process.env.API_BASE_URL ||
    process.env.EXPO_PUBLIC_GATEWAY_BASE_URL ||
    process.env.GATEWAY_BASE_URL,
  GATEWAY_BASE_URL
);

export const IDENTITY_BASE_URL = resolveConfigValue(
  'IDENTITY_BASE_URL',
  process.env.EXPO_PUBLIC_IDENTITY_BASE_URL || process.env.IDENTITY_BASE_URL,
  'http://localhost:8083'
);

export const NOTIFICATION_BASE_URL = resolveConfigValue(
  'NOTIFICATION_BASE_URL',
  process.env.EXPO_PUBLIC_NOTIFICATION_BASE_URL || process.env.NOTIFICATION_BASE_URL,
  'http://localhost:8082'
);

export const PROMOTION_BASE_URL = resolveConfigValue(
  'PROMOTION_BASE_URL',
  process.env.EXPO_PUBLIC_PROMOTION_BASE_URL || process.env.PROMOTION_BASE_URL,
  'http://localhost:8088'
);
