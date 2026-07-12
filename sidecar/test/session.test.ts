import { describe, it, expect, vi } from 'vitest';
import { WarmSession } from '../src/session.js';
import type { RefineRequest } from '../src/protocol.js';

const request: RefineRequest = {
  id: 'r1',
  type: 'refine',
  transcript: 'tell him im running late',
  context: 'John: are you close?',
  appName: 'Messages',
};

/**
 * Fake queryFn: consumes user messages from the prompt generator and yields a scripted
 * assistant + result pair per turn, echoing back part of the prompt so tests can assert
 * on framing.
 */
function fakeQuery(script?: { failFirstTurn?: boolean }) {
  const calls: string[][] = [];
  const queryFn = vi.fn((args: { prompt: AsyncIterable<any> }) => {
    const receivedPrompts: string[] = [];
    calls.push(receivedPrompts);
    let failNext = script?.failFirstTurn === true && calls.length === 1;

    async function* generate() {
      for await (const userMessage of args.prompt) {
        const text = userMessage.message.content[0].text as string;
        receivedPrompts.push(text);
        if (failNext) {
          failNext = false;
          yield { type: 'result', subtype: 'error_during_execution' };
          continue;
        }
        yield {
          type: 'assistant',
          message: { content: [{ type: 'text', text: `REFINED<${text.slice(0, 30)}>` }] },
        };
        yield { type: 'result', subtype: 'success', result: '' };
      }
    }
    const generator = generate() as any;
    generator.interrupt = async () => {};
    return generator;
  });
  return { queryFn, calls };
}

describe('WarmSession', () => {
  it('frames each request independently and returns assistant text', async () => {
    const { queryFn, calls } = fakeQuery();
    const session = new WarmSession({ systemPrompt: 'draft messages', queryFn: queryFn as any });

    const text = await session.refine(request);
    expect(text).toContain('REFINED<');

    const prompt = calls[0][0];
    expect(prompt).toContain('New independent request');
    expect(prompt).toContain('Target app: Messages');
    expect(prompt).toContain('John: are you close?');
    expect(prompt).toContain('tell him im running late');
    await session.close();
  });

  it('reuses one query process across multiple turns', async () => {
    const { queryFn, calls } = fakeQuery();
    const session = new WarmSession({ systemPrompt: 'draft', queryFn: queryFn as any });

    await session.refine(request);
    await session.refine({ ...request, id: 'r2', transcript: 'second message' });

    expect(queryFn).toHaveBeenCalledTimes(1); // warm: same process, two turns
    expect(calls[0].length).toBe(2);
    await session.close();
  });

  it('recycles after maxTurnsPerSession', async () => {
    const { queryFn } = fakeQuery();
    const session = new WarmSession({
      systemPrompt: 'draft',
      queryFn: queryFn as any,
      maxTurnsPerSession: 2,
    });

    await session.refine(request);
    await session.refine({ ...request, id: 'r2' });
    await session.refine({ ...request, id: 'r3' }); // third turn → new session

    expect(queryFn).toHaveBeenCalledTimes(2);
    await session.close();
  });

  it('rejects the turn when the SDK reports a failure result', async () => {
    const { queryFn } = fakeQuery({ failFirstTurn: true });
    const session = new WarmSession({ systemPrompt: 'draft', queryFn: queryFn as any });

    await expect(session.refine(request)).rejects.toThrow('turn failed');
    // Next request still succeeds (session still readable).
    const text = await session.refine({ ...request, id: 'r2' });
    expect(text).toContain('REFINED<');
    await session.close();
  });

  it('serializes concurrent refines', async () => {
    const { queryFn, calls } = fakeQuery();
    const session = new WarmSession({ systemPrompt: 'draft', queryFn: queryFn as any });

    const [a, b] = await Promise.all([
      session.refine({ ...request, id: 'c1', transcript: 'first' }),
      session.refine({ ...request, id: 'c2', transcript: 'second' }),
    ]);
    expect(a).toContain('REFINED<');
    expect(b).toContain('REFINED<');
    expect(calls[0].length).toBe(2);
    await session.close();
  });
});
