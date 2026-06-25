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
  it('renders null when API key is empty string', () => {
    const { container } = render(<GpsTrackMap points={twoPoints} apiKey="" />);
    expect(container).toBeEmptyDOMElement();
  });

  it('renders null when points array is empty', () => {
    const { container } = render(<GpsTrackMap points={[]} apiKey="test-key" />);
    expect(container).toBeEmptyDOMElement();
  });

  it('renders map container when valid points provided', () => {
    render(<GpsTrackMap points={twoPoints} apiKey="test-key" />);
    expect(screen.getByTestId('api-provider')).toBeInTheDocument();
    expect(screen.getByTestId('map')).toBeInTheDocument();
  });

  it('renders two markers for multi-point track', () => {
    render(<GpsTrackMap points={twoPoints} apiKey="test-key" />);
    expect(screen.getAllByTestId('advanced-marker')).toHaveLength(2);
  });

  it('renders one marker for single point', () => {
    render(<GpsTrackMap points={onePoint} apiKey="test-key" />);
    expect(screen.getAllByTestId('advanced-marker')).toHaveLength(1);
  });

  it('uses green pin for start marker and red pin for end marker', () => {
    render(<GpsTrackMap points={twoPoints} apiKey="test-key" />);
    const pins = screen.getAllByTestId('pin');
    expect(pins[0]).toHaveAttribute('data-background', '#22c55e');
    expect(pins[1]).toHaveAttribute('data-background', '#ef4444');
  });

  it('applies 400px height to map wrapper', () => {
    render(<GpsTrackMap points={twoPoints} apiKey="test-key" />);
    const wrapper = screen.getByTestId('map').parentElement;
    expect(wrapper).toHaveStyle({ height: '400px' });
  });
});
