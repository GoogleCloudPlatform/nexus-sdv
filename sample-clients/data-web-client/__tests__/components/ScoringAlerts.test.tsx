import { render, screen, act } from '@testing-library/react';
import Sidebar from '@/components/sidebar';

const mockClose = jest.fn();

class MockEventSource {
  onmessage: ((e: MessageEvent) => void) | null = null;
  onerror: (() => void) | null = null;
  close = mockClose;
  static instances: MockEventSource[] = [];
  constructor(public url: string) { MockEventSource.instances.push(this); }
  emit(data: string) { this.onmessage?.({ data } as MessageEvent); }
  emitError() { this.onerror?.(); }
}

jest.mock('next/navigation', () => ({ usePathname: () => '/fleet' }));
jest.mock('next-auth/react', () => ({
  useSession: () => ({ data: { user: { email: 'test@example.com' } } }),
  signOut: jest.fn(),
}));

beforeEach(() => {
  MockEventSource.instances = [];
  mockClose.mockReset();
  (global as unknown as { EventSource: unknown }).EventSource = MockEventSource;
});

describe('Sidebar scoring events', () => {
  it('opens an EventSource to /api/scoring/stream on mount', () => {
    render(<Sidebar />);
    expect(MockEventSource.instances[0].url).toBe('/api/scoring/stream');
  });

  it('shows placeholder when no messages received', () => {
    render(<Sidebar />);
    expect(screen.getByPlaceholderText('No events yet…')).toBeInTheDocument();
  });

  it('displays received messages newest-first in the textarea', () => {
    render(<Sidebar />);
    act(() => { MockEventSource.instances[0].emit('{"vehicle":"v1","score":1,"message":"m1"}'); });
    act(() => { MockEventSource.instances[0].emit('{"vehicle":"v2","score":2,"message":"m2"}'); });
    const textarea = screen.getByRole('textbox') as HTMLTextAreaElement;
    expect(textarea.value).toBe('v2 - 2 - m2\nv1 - 1 - m1');
  });

  it('falls back to raw text for non-JSON messages', () => {
    render(<Sidebar />);
    act(() => { MockEventSource.instances[0].emit('not-json'); });
    const textarea = screen.getByRole('textbox') as HTMLTextAreaElement;
    expect(textarea.value).toBe('not-json');
  });

  it('closes the EventSource on error', () => {
    render(<Sidebar />);
    MockEventSource.instances[0].emitError();
    expect(mockClose).toHaveBeenCalledTimes(1);
  });

  it('closes the EventSource on unmount', () => {
    const { unmount } = render(<Sidebar />);
    unmount();
    expect(mockClose).toHaveBeenCalledTimes(1);
  });
});
