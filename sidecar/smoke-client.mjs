import net from 'node:net';
import os from 'node:os';
import path from 'node:path';

const request = JSON.parse(process.argv[2]);
const socket = net.connect(path.join(os.homedir(), '.skvoice', 'sidecar.sock'));
const start = Date.now();
let buffer = '';
socket.on('connect', () => socket.write(JSON.stringify(request) + '\n'));
socket.on('data', (chunk) => {
  buffer += chunk.toString();
  const newline = buffer.indexOf('\n');
  if (newline !== -1) {
    console.log(`[${((Date.now() - start) / 1000).toFixed(2)}s]`, buffer.slice(0, newline));
    socket.end();
    process.exit(0);
  }
});
setTimeout(() => { console.error('client timeout'); process.exit(2); }, 60000);
