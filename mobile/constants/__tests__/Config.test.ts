import { resolveConfigValue } from '../Config';

describe('Config dynamic environment resolution (US-07 CA3)', () => {
  const originalRuntimeConfig = globalThis.__CIRCLEGUARD_CONFIG__;

  afterEach(() => {
    globalThis.__CIRCLEGUARD_CONFIG__ = originalRuntimeConfig;
  });

  it('prefers runtime window.__CIRCLEGUARD_CONFIG__ over build-time env and fallback', () => {
    globalThis.__CIRCLEGUARD_CONFIG__ = {
      GATEWAY_BASE_URL: 'https://stage-api.circleguard.internal:8087/',
      APP_ENV: 'stage',
    };

    expect(
      resolveConfigValue(
        'GATEWAY_BASE_URL',
        'http://dev-api.circleguard.internal:8087',
        'http://localhost:8087'
      )
    ).toBe('https://stage-api.circleguard.internal:8087');

    expect(resolveConfigValue('APP_ENV', 'dev', 'dev')).toBe('stage');
  });

  it('falls back to environment variable when runtime config is absent', () => {
    globalThis.__CIRCLEGUARD_CONFIG__ = undefined;

    expect(
      resolveConfigValue(
        'AUTH_BASE_URL',
        'http://172.31.17.179:8180/',
        'http://localhost:8180'
      )
    ).toBe('http://172.31.17.179:8180');
  });

  it('uses default localhost URL when neither runtime nor build-time variable is set', () => {
    globalThis.__CIRCLEGUARD_CONFIG__ = undefined;

    expect(resolveConfigValue('FORM_BASE_URL', undefined, 'http://localhost:8086/')).toBe(
      'http://localhost:8086'
    );
  });
});
