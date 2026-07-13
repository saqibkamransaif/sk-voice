/** NDJSON protocol between the Swift app and this sidecar. */

export type RefineMode = 'message' | 'prompt';

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
  mode: RefineMode;
}

export interface ReviseRequest {
  id: string;
  type: 'revise';
  draft: string;
  instruction: string;
  context: string;
  appName: string;
  mode: RefineMode;
}

export type SidecarRequest = PingRequest | RefineRequest | ReviseRequest;

export type SidecarResponse =
  | { id: string; type: 'pong' }
  | { id: string; type: 'result'; text: string }
  | { id: string; type: 'error'; message: string };

function stringField(obj: Record<string, unknown>, key: string): string {
  return typeof obj[key] === 'string' ? (obj[key] as string) : '';
}

function modeField(obj: Record<string, unknown>): RefineMode {
  return obj.mode === 'prompt' ? 'prompt' : 'message';
}

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
      context: stringField(obj, 'context'),
      appName: stringField(obj, 'appName'),
      mode: modeField(obj),
    };
  }
  if (obj.type === 'revise') {
    if (typeof obj.draft !== 'string' || obj.draft.length === 0) {
      return { parseError: 'missing draft' };
    }
    if (typeof obj.instruction !== 'string' || obj.instruction.length === 0) {
      return { parseError: 'missing instruction' };
    }
    return {
      id: obj.id,
      type: 'revise',
      draft: obj.draft,
      instruction: obj.instruction,
      context: stringField(obj, 'context'),
      appName: stringField(obj, 'appName'),
      mode: modeField(obj),
    };
  }
  return { parseError: `unknown type ${String(obj.type)}` };
}

export function encodeResponse(response: SidecarResponse): string {
  return JSON.stringify(response) + '\n';
}
