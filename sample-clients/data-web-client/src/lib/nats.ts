import { connect, type NatsConnection } from 'nats';

let _nc: NatsConnection | null = null;
let _scoringNc: NatsConnection | null = null;

export async function getNatsConnection(): Promise<NatsConnection> {
  if (!_nc || _nc.isClosed()) {
    _nc = await connect({
      servers: process.env.NATS_URL!,
      user: process.env.NATS_USER!,
      pass: process.env.NATS_PASSWORD!,
    });
  }
  return _nc;
}

export async function getNatsScoringConnection(): Promise<NatsConnection> {
  if (!_scoringNc || _scoringNc.isClosed()) {
    _scoringNc = await connect({
      servers: process.env.NATS_URL!,
      user: process.env.NATS_SCORING_USER!,
      pass: process.env.NATS_SCORING_PASSWORD!,
    });
  }
  return _scoringNc;
}

export function _resetNatsConnection() {
  _nc = null;
  _scoringNc = null;
}
