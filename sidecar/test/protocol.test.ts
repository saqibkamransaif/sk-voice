import { describe, it, expect } from 'vitest';
import { parseRequest, encodeResponse } from '../src/protocol.js';

describe('parseRequest', () => {
  it('parses a ping', () => {
    expect(parseRequest('{"id":"a1","type":"ping"}')).toEqual({ id: 'a1', type: 'ping' });
  });

  it('parses a refine with all fields', () => {
    const parsed = parseRequest(
      JSON.stringify({
        id: 'r1',
        type: 'refine',
        transcript: 'tell him im late',
        context: 'John: are you close?',
        appName: 'Messages',
      }),
    );
    expect(parsed).toEqual({
      id: 'r1',
      type: 'refine',
      transcript: 'tell him im late',
      context: 'John: are you close?',
      appName: 'Messages',
      mode: 'message',
    });
  });

  it('defaults missing context and appName to empty strings', () => {
    const parsed = parseRequest('{"id":"r2","type":"refine","transcript":"hi"}');
    expect(parsed).toEqual({ id: 'r2', type: 'refine', transcript: 'hi', context: '', appName: '', mode: 'message' });
  });

  it('rejects invalid JSON', () => {
    expect(parseRequest('{nope')).toEqual({ parseError: 'invalid JSON' });
  });

  it('rejects missing id', () => {
    expect(parseRequest('{"type":"ping"}')).toEqual({ parseError: 'missing id' });
  });

  it('rejects refine without transcript', () => {
    expect(parseRequest('{"id":"x","type":"refine"}')).toEqual({
      parseError: 'missing transcript',
    });
  });

  it('rejects unknown types', () => {
    expect(parseRequest('{"id":"x","type":"dance"}')).toEqual({ parseError: 'unknown type dance' });
  });
});

describe('encodeResponse', () => {
  it('encodes newline-terminated JSON', () => {
    const line = encodeResponse({ id: 'r1', type: 'result', text: 'Hello!' });
    expect(line.endsWith('\n')).toBe(true);
    expect(JSON.parse(line)).toEqual({ id: 'r1', type: 'result', text: 'Hello!' });
  });
});

describe('parseRequest revise', () => {
  it('parses a revise with all fields', () => {
    const parsed = parseRequest(
      JSON.stringify({
        id: 'v1',
        type: 'revise',
        draft: 'Hey John, running late.',
        instruction: 'make it more formal',
        context: 'ctx',
        appName: 'Mail',
        mode: 'message',
      }),
    );
    expect(parsed).toEqual({
      id: 'v1',
      type: 'revise',
      draft: 'Hey John, running late.',
      instruction: 'make it more formal',
      context: 'ctx',
      appName: 'Mail',
      mode: 'message',
    });
  });

  it('rejects revise without draft or instruction', () => {
    expect(parseRequest('{"id":"v2","type":"revise","instruction":"x"}')).toEqual({
      parseError: 'missing draft',
    });
    expect(parseRequest('{"id":"v3","type":"revise","draft":"x"}')).toEqual({
      parseError: 'missing instruction',
    });
  });

  it('parses prompt mode on refine', () => {
    const parsed = parseRequest(
      '{"id":"p1","type":"refine","transcript":"build me a parser","mode":"prompt"}',
    );
    expect(parsed).toMatchObject({ type: 'refine', mode: 'prompt' });
  });
});
