import { describe, it, expect, vi } from 'vitest';
import { WarmSession } from '../src/session.js';
import type { RefineRequest } from '../src/protocol.js';

const request: RefineRequest = {
  id: 'r1',
  type: 'refine',
  transcript: 'tell him im running late',
  context: 'John: are you close?',
  appName: 'Messages',
  mode: 'message',
  styleHint: '',
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

describe('WarmSession modes and revise', () => {
  it('uses prompt-enhancement framing in prompt mode', async () => {
    const { queryFn, calls } = fakeQuery();
    const session = new WarmSession({ systemPrompt: 'draft', queryFn: queryFn as any });

    await session.refine({ ...request, id: 'm1', mode: 'prompt', appName: 'Claude' });
    expect(calls[0][0]).toContain('PROMPT for an AI assistant');
    expect(calls[0][0]).toContain('Output ONLY the prompt text');
    await session.close();
  });

  it('uses message framing in message mode', async () => {
    const { queryFn, calls } = fakeQuery();
    const session = new WarmSession({ systemPrompt: 'draft', queryFn: queryFn as any });

    await session.refine({ ...request, id: 'm2', mode: 'message' });
    expect(calls[0][0]).toContain('MESSAGE to a person');
    await session.close();
  });

  it('revise includes draft and instruction', async () => {
    const { queryFn, calls } = fakeQuery();
    const session = new WarmSession({ systemPrompt: 'draft', queryFn: queryFn as any });

    const text = await session.revise({
      id: 'v1',
      type: 'revise',
      draft: 'Hey John, running late.',
      instruction: 'make it shorter',
      context: '',
      appName: 'Messages',
      mode: 'message',
    });
    expect(text).toContain('REFINED<');
    expect(calls[0][0]).toContain('Current message draft:\nHey John, running late.');
    expect(calls[0][0]).toContain('Revision instruction:\nmake it shorter');
    await session.close();
  });
});

describe('WarmSession styleHint and learn', () => {
  it('includes styleHint in refine framing', async () => {
    const { queryFn, calls } = fakeQuery();
    const session = new WarmSession({ systemPrompt: 'draft', queryFn: queryFn as any });

    await session.refine({ ...request, id: 's1', styleHint: 'short sentences, no emoji' });
    expect(calls[0][0]).toContain("The user's known writing style");
    expect(calls[0][0]).toContain('short sentences, no emoji');
    await session.close();
  });

  it('omits style section when hint empty', async () => {
    const { queryFn, calls } = fakeQuery();
    const session = new WarmSession({ systemPrompt: 'draft', queryFn: queryFn as any });

    await session.refine({ ...request, id: 's2', styleHint: '' });
    expect(calls[0][0]).not.toContain('known writing style');
    await session.close();
  });

  it('learn builds a profile-update turn from pairs', async () => {
    const { queryFn, calls } = fakeQuery();
    const session = new WarmSession({ systemPrompt: 'draft', queryFn: queryFn as any });

    const text = await session.learn({
      id: 'l1',
      type: 'learn',
      pairs: [
        { raw: 'tell him ok', final: 'Sounds good — go ahead!' },
        { raw: 'thanks bye', final: 'Thanks! Cheers, Saqib' },
      ],
      currentProfile: 'uses dashes',
    });
    expect(text).toContain('REFINED<');
    expect(calls[0][0]).toContain('UPDATED profile');
    expect(calls[0][0]).toContain('Dictated: tell him ok');
    expect(calls[0][0]).toContain('Final sent: Thanks! Cheers, Saqib');
    expect(calls[0][0]).toContain('Current profile:\nuses dashes');
    await session.close();
  });
});
