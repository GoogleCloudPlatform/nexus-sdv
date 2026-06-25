import { render, screen, fireEvent } from '@testing-library/react';
import DataTable from '@/components/data-table';

const testColumns = ['dynamic:temp', 'static:id'];
const testData = [
  { 'dynamic:temp': '25.0', 'static:id': 'abc' },
  { 'dynamic:temp': '26.0', 'static:id': 'def' },
];

describe('DataTable', () => {
  it('renders column headers with family prefix stripped', () => {
    render(<DataTable columnKeys={testColumns} data={testData} />);

    expect(screen.getByText('temp')).toBeInTheDocument();
    expect(screen.getByText('id')).toBeInTheDocument();
    expect(screen.queryByText('dynamic:temp')).not.toBeInTheDocument();
  });

  it('renders all data rows', () => {
    render(<DataTable columnKeys={testColumns} data={testData} />);

    expect(screen.getByText('25.0')).toBeInTheDocument();
    expect(screen.getByText('26.0')).toBeInTheDocument();
  });

  it('calls onRowClick with row data when row is clicked', () => {
    const onRowClick = jest.fn();
    render(<DataTable columnKeys={testColumns} data={testData} onRowClick={onRowClick} />);

    fireEvent.click(screen.getByText('25.0').closest('tr')!);

    expect(onRowClick).toHaveBeenCalledWith(testData[0]);
  });

  it('renders "—" for missing values', () => {
    const sparseData = [{ 'dynamic:temp': '25.0' }];
    render(<DataTable columnKeys={testColumns} data={sparseData} />);

    expect(screen.getByText('—')).toBeInTheDocument();
  });
});
