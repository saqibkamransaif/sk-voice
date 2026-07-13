import { query, type Query, type SDKUserMessage } from '@anthropic-ai/claude-agent-sdk';
import type { RefineRequest, ReviseRequest } from './protocol.js';

export interface SessionOptions {
  systemPrompt: string;
  model?: string;
  /** Injectable for tests. */
  queryFn?: typeof query;
  /** Recycle the warm session after this many turns to cap context growth. */
  maxTurnsPerSession?: number;
}

interface PendingTurn {
  resolve: (text: string) => void;
  reject: (error: Error) => void;
}

/**
 * A warm Claude Agent SDK session. Streaming-input mode keeps ONE long-lived CLI
 * process alive across turns, so refine requests skip cold start entirely.
 * Each request is framed as an independent turn; the session is recycled after
 * maxTurnsPerSession turns (or on error) to keep the context small.
 */
export class WarmSession {
  private readonly options: SessionOptions;
  private readonly queryFn: typeof query;
  private readonly maxTurns: number;

  private q: Query | null = null;
  private pushMessage: ((message: SDKUserMessage) => void) | null = null;
  private pending: PendingTurn | null = null;
  private turnCount = 0;
  private chain: Promise<void> = Promise.resolve();

  constructor(options: SessionOptions) {
    this.options = options;
    this.queryFn = options.queryFn ?? query;
    this.maxTurns = options.maxTurnsPerSession ?? 20;
  }

  /** Serialized: one turn in flight at a time. */
  refine(request: RefineRequest): Promise<string> {
    return this.enqueue(this.buildRefinePrompt(request));
  }

  revise(request: ReviseRequest): Promise<string> {
    return this.enqueue(this.buildRevisePrompt(request));
  }

  private enqueue(prompt: string): Promise<string> {
    const run = () => this.runTurn(prompt);
    const result = this.chain.then(run, run);
    this.chain = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }

  private buildRefinePrompt(request: RefineRequest): string {
    const shared = [
      'New independent request — ignore all previous turns entirely.',
      request.appName ? `Target app: ${request.appName}` : '',
      request.context ? `On-screen context:\n${request.context}` : '',
      `Dictated intent:\n${request.transcript}`,
    ];
    if (request.mode === 'prompt') {
      shared.push(
        [
          'The user is dictating a PROMPT for an AI assistant. Expand their intent into a',
          'clear, well-specified prompt: state the goal, include relevant context and',
          'constraints, and describe the expected output. Preserve every requirement they',
          'mentioned; do not invent new ones. Keep it as concise as clarity allows.',
          'Output ONLY the prompt text.',
        ].join(' '),
      );
    } else {
      shared.push(
        'The user is dictating a MESSAGE to a person. Write the polished message now, ' +
          'matching the tone of the conversation context. Output ONLY the message text.',
      );
    }
    return shared.filter(Boolean).join('\n\n');
  }

  private buildRevisePrompt(request: ReviseRequest): string {
    const kind = request.mode === 'prompt' ? 'prompt' : 'message';
    return [
      'New independent request — ignore all previous turns entirely.',
      request.appName ? `Target app: ${request.appName}` : '',
      request.context ? `On-screen context:\n${request.context}` : '',
      `Current ${kind} draft:\n${request.draft}`,
      `Revision instruction:\n${request.instruction}`,
      `Apply the instruction to the draft and output ONLY the revised ${kind} text.`,
    ]
      .filter(Boolean)
      .join('\n\n');
  }

  private async runTurn(prompt: string): Promise<string> {
    if (!this.q || this.turnCount >= this.maxTurns) {
      await this.recycle();
    }
    this.turnCount += 1;

    return new Promise<string>((resolve, reject) => {
      this.pending = { resolve, reject };
      this.pushMessage!({
        type: 'user',
        session_id: '',
        parent_tool_use_id: null,
        message: { role: 'user', content: [{ type: 'text', text: prompt }] },
      } as SDKUserMessage);
    });
  }

  /** Tear down any existing query and start a fresh warm one. */
  async recycle(): Promise<void> {
    await this.teardown();

    const queue: SDKUserMessage[] = [];
    let wake: (() => void) | null = null;
    let closed = false;

    this.pushMessage = (message) => {
      queue.push(message);
      wake?.();
    };
    const stop = () => {
      closed = true;
      wake?.();
    };
    this.stopInput = stop;

    async function* input(): AsyncGenerator<SDKUserMessage> {
      while (!closed) {
        while (queue.length > 0) yield queue.shift()!;
        if (closed) return;
        await new Promise<void>((resolve) => {
          wake = resolve;
        });
        wake = null;
      }
    }

    this.q = this.queryFn({
      prompt: input(),
      options: {
        systemPrompt: this.options.systemPrompt,
        ...(this.options.model ? { model: this.options.model } : {}),
        allowedTools: [],
        permissionMode: 'default',
        // Isolation from the user's Claude Code config: no hooks, no CLAUDE.md,
        // no MCP servers — this session only drafts messages, and skipping
        // settings shaves seconds off session startup.
        settingSources: [],
      },
    });
    this.turnCount = 0;

    // Reader loop: collect assistant text per turn; a `result` message ends the turn.
    void this.readLoop(this.q);
  }

  private stopInput: (() => void) | null = null;

  private async readLoop(q: Query): Promise<void> {
    let turnText = '';
    try {
      for await (const message of q) {
        if (this.q !== q) return; // stale reader after recycle
        const m = message as Record<string, any>;
        if (process.env.SKVOICE_DEBUG === '1') {
          console.error(`skvoice-sidecar: sdk msg ${m.type}${m.subtype ? '/' + m.subtype : ''}`);
        }
        if (m.type === 'assistant') {
          const blocks = m.message?.content ?? [];
          for (const block of blocks) {
            if (block.type === 'text') turnText += block.text;
          }
        } else if (m.type === 'result') {
          const pending = this.pending;
          this.pending = null;
          const text = turnText.trim();
          turnText = '';
          if (pending) {
            if (m.subtype === 'success' && text.length > 0) {
              pending.resolve(text);
            } else if (m.subtype === 'success' && typeof m.result === 'string' && m.result.trim()) {
              pending.resolve(m.result.trim());
            } else {
              pending.reject(new Error(`turn failed: ${m.subtype ?? 'empty result'}`));
            }
          }
        }
      }
      // Stream ended (CLI exited). Only the ACTIVE reader may fail the pending turn —
      // a stale reader ending after a recycle must not kill the new session's turn.
      if (this.q === q) {
        this.failPending(new Error('session stream ended'));
        this.q = null;
      }
    } catch (error) {
      if (this.q === q) {
        this.failPending(error instanceof Error ? error : new Error(String(error)));
        this.q = null;
      }
    }
  }

  private failPending(error: Error): void {
    const pending = this.pending;
    this.pending = null;
    pending?.reject(error);
  }

  private async teardown(): Promise<void> {
    this.failPending(new Error('session recycled'));
    this.stopInput?.();
    this.stopInput = null;
    this.pushMessage = null;
    this.q = null;
  }

  async close(): Promise<void> {
    await this.teardown();
  }
}
