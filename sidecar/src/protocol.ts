/** NDJSON protocol between the Swift app and this sidecar. */

export interface PingRequest {
  id: string;
  type: 'ping';
}

export interface RefineRequest {
  id: string;
  type: 'refine';
  transcript: string;
  context: string;
  appName: string;
}

export type SidecarRequest = PingRequest | RefineRequest;

export type SidecarResponse =
  | { id: string; type: 'pong' }
  | { id: string; type: 'result'; text: string }
  | { id: string; type: 'error'; message: string };

/** Parses one NDJSON line into a request, or returns an error string. */
export function parseRequest(line: string): SidecarRequest | { parseError: string } {
  let raw: unknown;
  try {
    raw = JSON.parse(line);
  } catch {
    return { parseError: 'invalid JSON' };
  }
  if (typeof raw !== 'object' || raw === null) return { parseError: 'not an object' };
  const obj = raw as Record<string, unknown>;
  if (typeof obj.id !== 'string' || obj.id.length === 0) {
    return { parseError: 'missing id' };
  }
  if (obj.type === 'ping') return { id: obj.id, type: 'ping' };
  if (obj.type === 'refine') {
    if (typeof obj.transcript !== 'string' || obj.transcript.length === 0) {
      return { parseError: 'missing transcript' };
    }
    return {
      id: obj.id,
      type: 'refine',
      transcript: obj.transcript,
      context: typeof obj.context === 'string' ? obj.context : '',
      appName: typeof obj.appName === 'string' ? obj.appName : '',
    };
  }
  return { parseError: `unknown type ${String(obj.type)}` };
}

export function encodeResponse(response: SidecarResponse): string {
  return JSON.stringify(response) + '\n';
}
