import net from 'node:net';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import readline from 'node:readline';
import { parseRequest, encodeResponse } from './protocol.js';
import { WarmSession } from './session.js';

const socketPath =
  process.env.SKVOICE_SOCKET ?? path.join(os.homedir(), '.skvoice', 'sidecar.sock');
const systemPrompt =
  process.env.SKVOICE_SYSTEM_PROMPT ??
  'You draft polished messages from dictated intent. Output ONLY the message text.';
const model = process.env.SKVOICE_MODEL || undefined;

fs.mkdirSync(path.dirname(socketPath), { recursive: true });
if (fs.existsSync(socketPath)) fs.unlinkSync(socketPath); // stale socket from a crash

const session = new WarmSession({ systemPrompt, model });

const server = net.createServer((connection) => {
  const rl = readline.createInterface({ input: connection });
  rl.on('line', (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    const request = parseRequest(trimmed);
    if ('parseError' in request) {
      connection.write(
        encodeResponse({ id: 'unknown', type: 'error', message: request.parseError }),
      );
      return;
    }
    if (request.type === 'ping') {
      connection.write(encodeResponse({ id: request.id, type: 'pong' }));
      return;
    }
    session
      .refine(request)
      .then((text) => {
        connection.write(encodeResponse({ id: request.id, type: 'result', text }));
      })
      .catch((error: Error) => {
        connection.write(
          encodeResponse({ id: request.id, type: 'error', message: error.message }),
        );
      });
  });
  connection.on('error', () => {
    /* client went away — nothing to do */
  });
});

server.listen(socketPath, () => {
  console.error(`skvoice-sidecar: listening on ${socketPath}`);
  // Pre-warm so the first real refine skips CLI startup.
  void session.recycle().catch((error: Error) => {
    console.error(`skvoice-sidecar: warm-up failed: ${error.message}`);
  });
});

function shutdown(): void {
  server.close();
  void session.close().finally(() => {
    if (fs.existsSync(socketPath)) fs.unlinkSync(socketPath);
    process.exit(0);
  });
}

process.on('SIGTERM', shutdown);
process.on('SIGINT', shutdown);
