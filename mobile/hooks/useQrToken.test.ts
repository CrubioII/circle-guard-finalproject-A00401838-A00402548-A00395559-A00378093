import { renderHook, act, waitFor } from '@testing-library/react-native';
import axios from 'axios';
import { useQrToken } from './useQrToken';

jest.mock('axios');
const mockedAxios = axios as jest.Mocked<typeof axios>;

describe('useQrToken', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    jest.clearAllMocks();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  test('should initialize with a token and 60s timer when anonymousId and authToken are present', async () => {
    mockedAxios.get.mockResolvedValueOnce({
      data: { qrToken: 'qr-token-initial', expiresIn: '60' },
    });

    const { result } = renderHook(() => useQrToken('test-id', 'jwt-token'));

    await waitFor(() => {
      expect(result.current.token).toBe('qr-token-initial');
    });
    expect(result.current.timeLeft).toBe(60);
  });

  test('should not initialize if anonymousId or authToken is null', () => {
    const { result } = renderHook(() => useQrToken(null, null));

    expect(result.current.token).toBeNull();
    expect(mockedAxios.get).not.toHaveBeenCalled();
  });

  test('should decrement timer every second', async () => {
    mockedAxios.get.mockResolvedValueOnce({
      data: { qrToken: 'qr-token-1', expiresIn: '60' },
    });

    const { result } = renderHook(() => useQrToken('test-id', 'jwt-token'));

    await waitFor(() => {
      expect(result.current.token).toBe('qr-token-1');
    });

    act(() => {
      jest.advanceTimersByTime(1000);
    });

    expect(result.current.timeLeft).toBe(59);
  });

  test('should rotate token and reset timer when it reaches 0', async () => {
    mockedAxios.get
      .mockResolvedValueOnce({
        data: { qrToken: 'qr-token-initial', expiresIn: '60' },
      })
      .mockResolvedValueOnce({
        data: { qrToken: 'qr-token-rotated', expiresIn: '60' },
      });

    const { result } = renderHook(() => useQrToken('test-id', 'jwt-token'));

    await waitFor(() => {
      expect(result.current.token).toBe('qr-token-initial');
    });
    const initialToken = result.current.token;

    await act(async () => {
      jest.advanceTimersByTime(60000);
    });

    await waitFor(() => {
      expect(result.current.token).toBe('qr-token-rotated');
    });
    expect(result.current.token).not.toBe(initialToken);
    expect(result.current.timeLeft).toBe(60);
  });
});
