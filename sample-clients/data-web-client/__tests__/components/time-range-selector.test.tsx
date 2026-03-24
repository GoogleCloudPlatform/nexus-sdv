import { render, screen, fireEvent } from '@testing-library/react';
import TimeRangeSelector from '@/components/time-range-selector';

describe('TimeRangeSelector', () => {
  it('renders all four range options', () => {
    render(<TimeRangeSelector value="1h" onChange={jest.fn()} />);

    expect(screen.getByText('1h')).toBeInTheDocument();
    expect(screen.getByText('6h')).toBeInTheDocument();
    expect(screen.getByText('24h')).toBeInTheDocument();
    expect(screen.getByText('7d')).toBeInTheDocument();
  });

  it('highlights the active range', () => {
    render(<TimeRangeSelector value="6h" onChange={jest.fn()} />);

    const active = screen.getByText('6h');
    expect(active).toHaveClass('bg-blue-600');

    const inactive = screen.getByText('1h');
    expect(inactive).not.toHaveClass('bg-blue-600');
  });

  it('calls onChange with selected range when a button is clicked', () => {
    const onChange = jest.fn();
    render(<TimeRangeSelector value="1h" onChange={onChange} />);

    fireEvent.click(screen.getByText('24h'));

    expect(onChange).toHaveBeenCalledWith('24h');
  });
});
