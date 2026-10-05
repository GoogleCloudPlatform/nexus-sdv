const mockQuery = jest.fn();

jest.mock('pg', () => ({
  Pool: jest.fn(() => ({ query: mockQuery })),
}));

import { getAllowedVehicleIds } from '@/lib/acl';

describe('getAllowedVehicleIds', () => {
  // getAllowedVehicleIds deliberately returns undefined when no ACL database is
  // configured (DB_NAME unset). These tests exercise the configured path, so set
  // it for this file only and restore it afterwards.
  const originalDbName = process.env.DB_NAME;
  beforeAll(() => {
    process.env.DB_NAME = 'nexus_acl';
  });
  afterAll(() => {
    if (originalDbName === undefined) delete process.env.DB_NAME;
    else process.env.DB_NAME = originalDbName;
  });

  beforeEach(() => {
    mockQuery.mockClear();
  });

  it('returns empty array and skips DB when groups is empty', async () => {
    const result = await getAllowedVehicleIds([]);
    expect(result).toEqual([]);
    expect(mockQuery).not.toHaveBeenCalled();
  });

  it('returns vehicle IDs for a single group', async () => {
    mockQuery.mockResolvedValueOnce({
      rows: [{ vehicle_id: 'vin-001' }, { vehicle_id: 'vin-002' }],
    });

    const result = await getAllowedVehicleIds(['fleet-a']);

    expect(result).toEqual(['vin-001', 'vin-002']);
    expect(mockQuery).toHaveBeenCalledWith(
      'SELECT DISTINCT vehicle_id FROM vehicle_groups WHERE group_name = ANY($1)',
      [['fleet-a']],
    );
  });

  it('returns vehicle IDs for multiple groups', async () => {
    mockQuery.mockResolvedValueOnce({
      rows: [{ vehicle_id: 'vin-001' }, { vehicle_id: 'vin-003' }],
    });

    const result = await getAllowedVehicleIds(['fleet-a', 'fleet-b']);

    expect(result).toEqual(['vin-001', 'vin-003']);
    expect(mockQuery).toHaveBeenCalledWith(
      'SELECT DISTINCT vehicle_id FROM vehicle_groups WHERE group_name = ANY($1)',
      [['fleet-a', 'fleet-b']],
    );
  });

  it('returns empty array when no vehicles match', async () => {
    mockQuery.mockResolvedValueOnce({ rows: [] });

    const result = await getAllowedVehicleIds(['fleet-unknown']);

    expect(result).toEqual([]);
  });
});
