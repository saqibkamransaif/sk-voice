// Minimal fake sidecar for SidecarClient integration tests.
// Speaks the same NDJSON protocol; refine responses are canned.
// SKVOICE_FAKE_DELAY_MS delays refine responses (for timeout tests).
const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');
const readline = require('node:readline');

const socketPath = process.env.SKVOICE_SOCKET;
const delayMs = parseInt(process.env.SKVOICE_FAKE_DELAY_MS || '0', 10);

fs.mkdirSync(path.dirname(socketPath), { recursive: true });
if (fs.existsSync(socketPath)) fs.unlinkSync(socketPath);

const server = net.createServer((connection) => {
  const rl = readline.createInterface({ input: connection });
  rl.on('line', (line) => {
    let request;
    try {
      request = JSON.parse(line);
    } catch {
      return;
    }
    if (request.type === 'ping') {
      connection.write(JSON.stringify({ id: request.id, type: 'pong' }) + '\n');
    } else if (request.type === 'refine') {
      setTimeout(() => {
        connection.write(
          JSON.stringify({
            id: request.id,
            type: 'result',
            text: `FAKE-REFINED: ${request.transcript}`,
          }) + '\n',
        );
      }, delayMs);
    }
  });
  connection.on('error', () => {});
});

server.listen(socketPath, () => console.error('fake-sidecar ready'));
