import "server-only";
import { env } from "../env";
import { withUser } from "../db";
import { MockProvider } from "./mock";
import { OpenAICompatibleProvider } from "./openai";
import { AIError, type AIProvider } from "./provider";

export { AIError, userMessageForAIError } from "./provider";
export { PROMPT_VERSIONS } from "./prompts";

let provider: AIProvider | undefined;

export function getProvider(): AIProvider {
  if (provider) return provider;
  const e = env();
  provider =
    e.AI_PROVIDER === "openai"
      ? new OpenAICompatibleProvider({
          baseUrl: e.AI_BASE_URL,
          apiKey: e.AI_API_KEY!,
          model: e.AI_MODEL!,
          jsonMode: e.AI_JSON_MODE,
          timeoutMs: e.AI_TIMEOUT_MS,
          maxRetries: e.AI_MAX_RETRIES,
        })
      : new MockProvider();
  return provider;
}

const localProvider = new MockProvider();

/**
 * The provider for a user. When the user has switched AI assistance off, the
 * local deterministic provider is used, so no profile data leaves the server.
 */
export async function providerForUser(userId: string): Promise<AIProvider> {
  const row = await withUser(userId, (db) =>
    db.one<{ ai_assistance_enabled: boolean }>("select ai_assistance_enabled from user_settings where user_id = $1", [userId]),
  );
  return row && !row.ai_assistance_enabled ? localProvider : getProvider();
}

/**
 * Records an AI operation and enforces the per-user hourly limit. Stored in the
 * database (metadata only) so the limit holds across server instances.
 */
export async function consumeAIQuota(userId: string, operation: string): Promise<void> {
  const limit = env().AI_RATE_LIMIT_PER_HOUR;
  await withUser(userId, async (db) => {
    const row = await db.one<{ n: number }>(
      "select count(*)::int as n from ai_requests where user_id = $1 and created_at > now() - interval '1 hour'",
      [userId],
    );
    if ((row?.n ?? 0) >= limit) {
      throw new AIError("rate_limited", `You have reached the limit of ${limit} AI operations per hour. Please try again later.`);
    }
    await db.query("insert into ai_requests (user_id, operation) values ($1, $2)", [userId, operation]);
  });
}
