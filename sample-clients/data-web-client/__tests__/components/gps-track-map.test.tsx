import { render, screen } from '@testing-library/react';
import GpsTrackMap from '@/components/gps-track-map';
import type { GpsPoint } from '@/lib/gps';

// Mock @vis.gl/react-google-maps — needs real browser + Maps JS API to function
jest.mock('@vis.gl/react-google-maps', () => ({
  APIProvider: ({ children }: { children: React.ReactNode }) => (
    <div data-testid="api-provider">{children}</div>
  ),
  Map: ({ children, style }: { children?: React.ReactNode; style?: React.CSSProperties }) => (
    <div data-testid="map" style={style}>{children}</div>
  ),
  AdvancedMarker: ({ children }: { children?: React.ReactNode }) => (
    <div data-testid="advanced-marker">{children}</div>
  ),
  Pin: ({ background }: { background: string }) => (
    <div data-testid="pin" data-background={background} />
  ),
  useMap: () => null,
  useMapsLibrary: () => null,
}));

const twoPoints: GpsPoint[] = [
  { timestamp: '2026-03-25T10:00:00Z', lat: 51.5, lng: -0.1, alt: 10 },
  { timestamp: '2026-03-25T10:01:00Z', lat: 51.6, lng: -0.2, alt: 20 },
];

const onePoint: GpsPoint[] = [
  { timestamp: '2026-03-25T10:00:00Z', lat: 51.5, lng: -0.1, alt: 10 },
];

describe('GpsTrackMap', () => {
  const originalEnv = process.env;

  beforeEach(() => {
    process.env = { ...originalEnv };
  });

  afterEach(() => {
    process.env = originalEnv;
  });

  it('renders null when API key is missing', () => {
    delete process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY;
    const { container } = render(<GpsTrackMap points={twoPoints} />);
    expect(container).toBeEmptyDOMElement();
  });

  it('renders null when points array is empty', () => {
    process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY = 'test-key';
    const { container } = render(<GpsTrackMap points={[]} />);
    expect(container).toBeEmptyDOMElement();
  });

  it('renders map container when valid points provided', () => {
    process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY = 'test-key';
    render(<GpsTrackMap points={twoPoints} />);
    expect(screen.getByTestId('api-provider')).toBeInTheDocument();
    expect(screen.getByTestId('map')).toBeInTheDocument();
  });

  it('renders two markers for multi-point track', () => {
    process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY = 'test-key';
    render(<GpsTrackMap points={twoPoints} />);
    expect(screen.getAllByTestId('advanced-marker')).toHaveLength(2);
  });

  it('renders one marker for single point', () => {
    process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY = 'test-key';
    render(<GpsTrackMap points={onePoint} />);
    expect(screen.getAllByTestId('advanced-marker')).toHaveLength(1);
  });

  it('uses green pin for start marker and red pin for end marker', () => {
    process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY = 'test-key';
    render(<GpsTrackMap points={twoPoints} />);
    const pins = screen.getAllByTestId('pin');
    expect(pins[0]).toHaveAttribute('data-background', '#22c55e');
    expect(pins[1]).toHaveAttribute('data-background', '#ef4444');
  });

  it('applies 400px height to map wrapper', () => {
    process.env.NEXT_PUBLIC_GOOGLE_MAPS_API_KEY = 'test-key';
    render(<GpsTrackMap points={twoPoints} />);
    const wrapper = screen.getByTestId('map').parentElement;
    expect(wrapper).toHaveStyle({ height: '400px' });
  });
});
